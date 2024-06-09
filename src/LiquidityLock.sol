// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { BaseHook } from "v4-periphery/BaseHook.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { CurrencySettler } from "lib/v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";

import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";

// Liquidity Lock is a hook that allows users to lock their liquidity for a certain period of time and earn rewards.
// The rewards can be deposited by any user permissionlessly according to their specifications.
// For this prototype, LPs who decide to lock their rewards are immediately paid out the rewards upon locking.

contract LiquidityLock is BaseHook {
  using CurrencyLibrary for Currency;
  using CurrencySettler for Currency;
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  bytes internal constant ZERO_BYTES = bytes("");

  mapping(PoolId poolId => mapping(int24 tickLower => mapping(int24 tickUpper => mapping(LockDuration => Rewards[]))))
    public availableRewards;

  mapping(address user => Lock[]) public userLocks;

  ////////////////////////////////////////////////
  //              ENUMS & STRUCTS               //
  ////////////////////////////////////////////////

  enum LockDuration {
    ONE_MONTH, // 0
    THREE_MONTHS, // 1
    SIX_MONTHS, // 2
    ONE_YEAR, // 3
    TWO_YEARS, // 4
    FOUR_YEARS, // 5
    SIX_YEARS, // 6
    TEN_YEARS, // 7
    TWENTY_YEARS, // 8
    ONE_HUNDRED_YEARS // 9
  }

  struct CallbackData {
    address sender;
    PoolKey key;
    IPoolManager.ModifyLiquidityParams params;
  }

  struct TokenAmount {
    address token;
    uint256 amount;
  }

  struct Rewards {
    uint256 rewardIdx;
    uint128 liquidity;
    address funder;
    TokenAmount[] tokenAmounts;
  }

  struct AddRewardsParams {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    LockDuration lockDuration;
    TokenAmount[] tokenAmounts;
  }

  struct RemoveRewardsParams {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    LockDuration lockDuration;
    address rewardToken;
    uint256 idx;
  }

  struct LockLiquidityParams {
    PoolKey key;
    IPoolManager.ModifyLiquidityParams modifyLiquidityParams;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
    uint256 rewardIdx;
    LockDuration lockDuration;
  }

  struct Lock {
    uint256 lockId;
    uint256 lockDate;
    uint128 liquidity;
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    LockDuration lockDuration;
    bool unlockedAndWithdrawn;
    address user;
    TokenAmount[] rewardsAmounts;
  }

  ////////////////////////////////////////////////
  //              EVENTS & ERRORS               //
  ////////////////////////////////////////////////

  event CreateRewards(
    bytes indexed rewards,
    uint128 indexed liquidity,
    LockDuration indexed lockDuration,
    address funder
  );

  error SenderMustBeHook();
  error PoolNotInitialized();
  error NoLiquidityToLock();
  error TooMuchSlippage();
  error CannotUnlockYet(uint256 unlockDate);
  error AlreadyUnlocked();
  error InvalidDuration();
  error NotRewardsFunder();

  ////////////////////////////////////////////////
  //                    SETUP                   //
  ////////////////////////////////////////////////

  constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return
      Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: true,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: true,
        afterRemoveLiquidity: false,
        beforeSwap: false,
        afterSwap: false,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
      });
  }

  function beforeAddLiquidity(
    address sender,
    PoolKey calldata,
    IPoolManager.ModifyLiquidityParams calldata,
    bytes calldata
  ) external view override returns (bytes4) {
    if (sender != address(this)) revert SenderMustBeHook();

    return IHooks.beforeAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(
    address sender,
    PoolKey calldata,
    IPoolManager.ModifyLiquidityParams calldata,
    bytes calldata
  ) external view override returns (bytes4) {
    if (sender != address(this)) revert SenderMustBeHook();

    return IHooks.beforeRemoveLiquidity.selector;
  }

  function unlockCallback(
    bytes calldata rawData
  ) external override(IUnlockCallback, BaseHook) poolManagerOnly returns (bytes memory) {
    CallbackData memory data = abi.decode(rawData, (CallbackData));
    BalanceDelta delta;

    if (data.params.liquidityDelta > 0) {
      (delta, ) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
      _settleDeltas(data.sender, data.key, delta);
    } else {
      (delta, ) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
      _takeDeltas(data.sender, data.key, delta);
    }
    return abi.encode(delta);
  }

  function _modifyLiquidity(
    PoolKey memory key,
    IPoolManager.ModifyLiquidityParams memory params
  ) internal returns (BalanceDelta delta) {
    delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
  }

  function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
    key.currency0.settle(poolManager, sender, uint256(int256(-delta.amount0())), false);
    key.currency1.settle(poolManager, sender, uint256(int256(-delta.amount1())), false);
  }

  function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
    poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
    poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
  }

  ////////////////////////////////////////////////
  //             MUTATIVE FUNCTIONS             //
  ////////////////////////////////////////////////

  function addRewards(AddRewardsParams calldata params) external {
    PoolId poolId = PoolIdLibrary.toId(params.key);

    uint256 rewardIdx = availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration].length;

    availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration].push(
      Rewards({
        rewardIdx: rewardIdx,
        funder: msg.sender,
        tokenAmounts: params.tokenAmounts,
        liquidity: params.liquidity
      })
    );

    for (uint256 i = 0; i < params.tokenAmounts.length; i++) {
      IERC20(params.tokenAmounts[i].token).transferFrom(msg.sender, address(this), params.tokenAmounts[i].amount);
    }

    emit CreateRewards(abi.encode(params.tokenAmounts), params.liquidity, params.lockDuration, msg.sender);
  }

  function removeRewards(RemoveRewardsParams calldata params) external {
    PoolId poolId = PoolIdLibrary.toId(params.key);

    Rewards storage reward = availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration][
      params.idx
    ];

    if (msg.sender != reward.funder) revert NotRewardsFunder();

    delete availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration][params.idx];

    for (uint256 i = 0; i < reward.tokenAmounts.length; i++) {
      IERC20(reward.tokenAmounts[i].token).transfer(msg.sender, reward.tokenAmounts[i].amount);
    }
  }

  function lockLiquidity(LockLiquidityParams calldata params) external returns (uint128 liquidityLocked) {
    PoolId poolId = params.key.toId();
    (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

    if (sqrtPriceX96 == 0) revert PoolNotInitialized();

    uint128 liquidityToLock = LiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      TickMath.getSqrtPriceAtTick(params.modifyLiquidityParams.tickLower),
      TickMath.getSqrtPriceAtTick(params.modifyLiquidityParams.tickUpper),
      params.amount0Desired,
      params.amount1Desired
    );

    if (liquidityToLock <= 0) revert NoLiquidityToLock();

    Rewards storage rewards = availableRewards[poolId][params.modifyLiquidityParams.tickLower][
      params.modifyLiquidityParams.tickUpper
    ][params.lockDuration][params.rewardIdx];

    TokenAmount[] memory rewardsAmounts = _calculateRewardAmount(rewards, liquidityToLock);

    _createLock(params, liquidityToLock, rewardsAmounts);

    BalanceDelta addedDelta = _modifyLiquidity(
      params.key,
      IPoolManager.ModifyLiquidityParams({
        tickLower: params.modifyLiquidityParams.tickLower,
        tickUpper: params.modifyLiquidityParams.tickUpper,
        liquidityDelta: int256(uint256(liquidityToLock)),
        salt: 0
      })
    );

    if (uint128(-addedDelta.amount0()) < params.amount0Min || uint128(-addedDelta.amount1()) < params.amount1Min) {
      revert TooMuchSlippage();
    }

    for (uint256 i = 0; i < rewardsAmounts.length; i++) {
      IERC20(rewardsAmounts[i].token).transfer(msg.sender, rewardsAmounts[i].amount);
    }

    return liquidityToLock;
  }

  function unlockLiquidity(uint256 lockId) external {
    Lock storage lock = userLocks[msg.sender][lockId];

    if (block.timestamp < lock.lockDate + durationToSeconds(lock.lockDuration))
      revert CannotUnlockYet(lock.lockDate + durationToSeconds(lock.lockDuration));

    if (lock.unlockedAndWithdrawn) revert AlreadyUnlocked();

    lock.unlockedAndWithdrawn = true;

    _modifyLiquidity(
      lock.key,
      IPoolManager.ModifyLiquidityParams({
        tickLower: lock.tickLower,
        tickUpper: lock.tickUpper,
        liquidityDelta: -int256(uint256(lock.liquidity)),
        salt: 0
      })
    );
  }

  ////////////////////////////////////////////////
  //              HELPER FUNTIONS              //
  ////////////////////////////////////////////////
  function _calculateRewardAmount(
    Rewards storage rewards,
    uint128 liquidityToLock
  ) internal returns (TokenAmount[] memory calculatedRewards) {
    uint128 effectiveLiquidity = liquidityToLock < rewards.liquidity ? liquidityToLock : rewards.liquidity;
    uint256 liquidityRewardsRatio = (uint256(effectiveLiquidity) * 1e18) / rewards.liquidity;

    TokenAmount[] memory rewardsAmounts = new TokenAmount[](rewards.tokenAmounts.length);

    for (uint256 i = 0; i < rewards.tokenAmounts.length; i++) {
      uint256 rewardAmount = (rewards.tokenAmounts[i].amount * liquidityRewardsRatio) / 1e18;
      rewards.tokenAmounts[i].amount -= rewardAmount;

      rewardsAmounts[i] = TokenAmount({ token: rewards.tokenAmounts[i].token, amount: rewardAmount });
    }

    rewards.liquidity -= effectiveLiquidity;

    return rewardsAmounts;
  }

  function _createLock(
    LockLiquidityParams calldata params,
    uint128 liquidity,
    TokenAmount[] memory rewardsAmounts
  ) internal {
    Lock memory newLock = Lock({
      lockId: userLocks[msg.sender].length,
      lockDate: block.timestamp,
      liquidity: liquidity,
      key: params.key,
      tickLower: params.modifyLiquidityParams.tickLower,
      tickUpper: params.modifyLiquidityParams.tickUpper,
      lockDuration: params.lockDuration,
      unlockedAndWithdrawn: false,
      user: msg.sender,
      rewardsAmounts: rewardsAmounts
    });

    userLocks[msg.sender].push(newLock);
  }

  function durationToSeconds(LockDuration duration) public pure returns (uint256) {
    if (duration == LockDuration.ONE_MONTH) return 30 days;
    if (duration == LockDuration.THREE_MONTHS) return 90 days;
    if (duration == LockDuration.SIX_MONTHS) return 180 days;
    if (duration == LockDuration.ONE_YEAR) return 365 days;
    if (duration == LockDuration.TWO_YEARS) return 730 days;
    if (duration == LockDuration.FOUR_YEARS) return 1460 days;
    if (duration == LockDuration.SIX_YEARS) return 2190 days;
    if (duration == LockDuration.TEN_YEARS) return 3650 days;
    if (duration == LockDuration.TWENTY_YEARS) return 7300 days;
    if (duration == LockDuration.ONE_HUNDRED_YEARS) return 36500 days; // Approximation for 100 years
    revert InvalidDuration();
  }
}
