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

/// @title Liquidity Lock Contract for Pool Liquidity Management
/// @notice This contract provides functionalities to lock liquidity into pools, manage rewards, and handle lock/unlock events.
// Liquidity Lock is a hook that allows users to lock their liquidity for a certain period of time and earn rewards.
// The rewards can be deposited by any user permissionlessly according to their specifications.
// For this prototype, LPs who decide to lock their rewards are immediately paid out the rewards upon locking.
contract LiquidityLock is BaseHook, IUnlockCallback {
  using CurrencyLibrary for Currency;
  using CurrencySettler for Currency;
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  bytes internal constant ZERO_BYTES = bytes("");

  /// @notice Rewards available per pool, indexed by PoolId and position ticks.
  mapping(PoolId => mapping(int24 lowerTick => mapping(int24 upperTick => mapping(LockDuration => Rewards[]))))
    public availableRewards;

  /// @notice Locks per user, allowing tracking of individual liquidity locks.
  mapping(address => Lock[]) public userLocks;

  ////////////////////////////////////////////////
  //              ENUMS & STRUCTS               //
  ////////////////////////////////////////////////

  /// @notice Duration options for liquidity locks, ranging from one month to one hundred years.
  enum LockDuration {
    ONE_MONTH,
    THREE_MONTHS,
    SIX_MONTHS,
    ONE_YEAR,
    TWO_YEARS,
    FOUR_YEARS,
    SIX_YEARS,
    TEN_YEARS,
    TWENTY_YEARS,
    ONE_HUNDRED_YEARS
  }

  /// @notice Data passed during unlocking liquidity callback, includes sender and key info.
  /// @param sender Address of the sender initiating the unlock.
  /// @param key The pool key associated with the liquidity position.
  /// @param params Parameters for modifying liquidity.
  struct CallbackData {
    address sender;
    PoolKey key;
    IPoolManager.ModifyLiquidityParams params;
  }

  /// @notice Details of rewards set for locked liquidity.
  /// @param rewardIdx Index of the reward in the storage array.
  /// @param funder Address of the user who funds the rewards.
  /// @param liquidity Amount of liquidity locked that qualifies for rewards.
  /// @param tokens Array of token addresses for rewards.
  /// @param amounts Array of amounts for each reward token.
  struct Rewards {
    uint256 rewardIdx;
    address funder;
    uint128 liquidity;
    address[] tokens;
    uint256[] amounts;
  }

  /// @notice Parameters for adding rewards to a pool.
  /// @param key The pool key to identify the liquidity pool.
  /// @param liquidity Amount of liquidity associated with the reward.
  /// @param tickLower Lower tick of the liquidity range.
  /// @param tickUpper Upper tick of the liquidity range.
  /// @param lockDuration Duration for which the liquidity must be locked to qualify for rewards.
  /// @param tokens Array of token addresses for rewards.
  /// @param amounts Array of amounts for each reward token.
  struct AddRewardsParams {
    PoolKey key;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    LockDuration lockDuration;
    address[] tokens;
    uint256[] amounts;
  }

  /// @notice Parameters for removing rewards from a pool.
  /// @param key The pool key to identify the liquidity pool.
  /// @param tickLower Lower tick of the liquidity range.
  /// @param tickUpper Upper tick of the liquidity range.
  /// @param lockDuration Duration for which the rewards were set.
  /// @param idx Index of the reward in the storage array.
  struct RemoveRewardsParams {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    LockDuration lockDuration;
    uint256 idx;
  }

  /// @notice Parameters for locking liquidity in a pool.
  /// @param key The pool key to identify the liquidity pool.
  /// @param modifyLiquidityParams Parameters needed to modify liquidity.
  /// @param amount0Desired Desired amount of token0 to lock.
  /// @param amount1Desired Desired amount of token1 to lock.
  /// @param amount0Min Minimum amount of token0 to lock to prevent slippage.
  /// @param amount1Min Minimum amount of token1 to lock to prevent slippage.
  /// @param deadline Time by which the transaction must be processed.
  /// @param rewardIdx Index of the reward in the storage array.
  /// @param lockDuration Duration for which the liquidity is locked.
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

  /// @notice Details of a user's locked liquidity.
  /// @param lockId Unique identifier for the lock.
  /// @param lockDate Timestamp when the liquidity was locked.
  /// @param liquidity Amount of liquidity locked.
  /// @param key The pool key associated with the locked liquidity.
  /// @param tickLower Lower tick of the locked liquidity range.
  /// @param tickUpper Upper tick of the locked liquidity range.
  /// @param lockDuration Duration for which the liquidity is locked.
  /// @param unlockedAndWithdrawn Whether the liquidity has been unlocked and withdrawn.
  /// @param user Address of the user who owns the lock.
  /// @param tokens Array of token addresses for rewards.
  /// @param rewardsAmounts Array of amounts for each reward token.
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
    address[] tokens;
    uint256[] rewardsAmounts;
  }

  ////////////////////////////////////////////////
  //              EVENTS & ERRORS               //
  ////////////////////////////////////////////////

  /// @notice Emitted when rewards are added to a pool.
  /// @param rewards Data packet containing the rewards information.
  /// @param liquidity Amount of liquidity associated with the rewards.
  /// @param lockDuration Duration for which the rewards are applicable.
  /// @param funder Address of the user who funded the rewards.
  event AddRewards(bytes indexed rewards, uint128 indexed liquidity, LockDuration indexed lockDuration, address funder);

  /// @notice Emitted when rewards are removed from a pool.
  /// @param rewards Data packet containing the rewards information.
  /// @param liquidity Amount of liquidity associated with the rewards being removed.
  /// @param lockDuration Duration for which the rewards were applicable.
  /// @param funder Address of the user who initially funded the rewards.
  event RemoveRewards(
    bytes indexed rewards,
    uint128 indexed liquidity,
    LockDuration indexed lockDuration,
    address funder
  );

  /// @notice Emitted when liquidity is locked in a pool.
  /// @param key The pool key associated with the liquidity lock.
  /// @param rewards Data packet containing the rewards information.
  /// @param liquidity Amount of liquidity locked.
  event LockLiquidity(PoolKey indexed key, bytes indexed rewards, uint128 indexed liquidity);

  /// @notice Emitted when a new liquidity lock is created.
  /// @param key The pool key associated with the liquidity lock.
  /// @param liquidity Amount of liquidity locked.
  /// @param user Address of the user who created the lock.
  /// @param lockDuration Duration for which the liquidity is locked.
  event CreateLock(PoolKey indexed key, uint128 indexed liquidity, address indexed user, LockDuration lockDuration);

  /// @notice Emitted when liquidity is unlocked from a pool.
  /// @param lockId Unique identifier for the liquidity lock.
  /// @param user Address of the user who unlocked the liquidity.
  /// @param liquidity Amount of liquidity unlocked.
  event UnlockLiquidity(uint256 indexed lockId, address indexed user, uint128 indexed liquidity);

  /// @notice Error thrown when an operation that requires the hook sender fails.
  error SenderMustBeHook();

  /// @notice Error thrown when a pool is not initialized but an operation requiring an initialized pool is attempted.
  error PoolNotInitialized();

  /// @notice Error thrown when there is no liquidity to lock.
  error NoLiquidityToLock();

  /// @notice Error thrown when the actual locked amounts are less than the specified minimums, indicating too much slippage.
  error TooMuchSlippage();

  /// @notice Error thrown when an attempt to unlock liquidity is made before the lock duration expires.
  /// @param unlockDate The timestamp when the liquidity can be unlocked.
  error CannotUnlockYet(uint256 unlockDate);

  /// @notice Error thrown when an attempt is made to unlock liquidity that has already been unlocked.
  error AlreadyUnlocked();

  /// @notice Error thrown when an invalid lock duration is provided.
  error InvalidDuration();

  /// @notice Error thrown when the caller is not the funder of the rewards they are trying to remove.
  error NotRewardsFunder();

  /// @notice Error thrown when a transaction is attempted past the provided deadline.
  error ExpiredPastDeadline();

  /// @notice Error thrown when the number of tokens and amounts does not match in a rewards operation.
  error TokensAndAmountsMismatch();

  ////////////////////////////////////////////////
  //                 SETUP                      //
  ////////////////////////////////////////////////

  /// @dev Initializes a new LiquidityLock contract linked to a specific PoolManager.
  /// @param _poolManager Address of the PoolManager contract this LiquidityLock will interact with.
  constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

  /// @notice Ensures that a given deadline has not passed.
  /// @param deadline The timestamp before which the transaction must be mined.
  modifier ensure(uint256 deadline) {
    if (deadline < block.timestamp) revert ExpiredPastDeadline();
    _;
  }

  /// @notice Retrieves the hook permissions for the contract.
  /// @return A struct detailing which liquidity pool operations trigger the hook methods.
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

  /// @notice Hook that is called before liquidity is added. Forces user to use hook to add liquidity.
  function beforeAddLiquidity(
    address sender,
    PoolKey calldata,
    IPoolManager.ModifyLiquidityParams calldata,
    bytes calldata
  ) external view override returns (bytes4) {
    if (sender != address(this)) revert SenderMustBeHook();
    return IHooks.beforeAddLiquidity.selector;
  }

  /// @notice Hook that is called before liquidity is removed. Forces user to use hook to remove liquidity.
  function beforeRemoveLiquidity(
    address sender,
    PoolKey calldata,
    IPoolManager.ModifyLiquidityParams calldata,
    bytes calldata
  ) external view override returns (bytes4) {
    if (sender != address(this)) revert SenderMustBeHook();
    return IHooks.beforeRemoveLiquidity.selector;
  }

  /// @notice Callback function invoked during the unlock of liquidity, executing any required state changes.
  /// @param rawData Encoded data containing details for the unlock operation.
  /// @return Encoded result of the liquidity modification.
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

  /// @notice Internal function to modify liquidity settings based on the provided parameters.
  /// @param key The pool key associated with the liquidity modification.
  /// @param params The liquidity modification parameters.
  /// @return delta The resulting balance changes from the liquidity modification.
  function _modifyLiquidity(
    PoolKey memory key,
    IPoolManager.ModifyLiquidityParams memory params
  ) internal returns (BalanceDelta delta) {
    delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
  }

  /// @notice Settles any owed balances after liquidity modification.
  /// @param sender Address of the user performing the liquidity modification.
  /// @param key The pool key associated with the liquidity modification.
  /// @param delta The balance delta resulting from the liquidity modification.
  function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
    key.currency0.settle(poolManager, sender, uint256(int256(-delta.amount0())), false);
    key.currency1.settle(poolManager, sender, uint256(int256(-delta.amount1())), false);
  }

  /// @notice Takes owed balances after liquidity modification.
  /// @param sender Address of the user performing the liquidity modification.
  /// @param key The pool key associated with the liquidity modification.
  /// @param delta The balance delta resulting from the liquidity modification.
  function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
    poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
    poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
  }

  ////////////////////////////////////////////////
  //               MUTATIVE FUNCTION            //
  ////////////////////////////////////////////////

  /// @notice Adds rewards to a specific liquidity pool's tick range.
  /// @dev Ensures that the token and amount arrays are of equal length to avoid mismatch errors.
  /// @param params Parameters containing details of the rewards to add.
  function addRewards(AddRewardsParams calldata params) external {
    if (params.tokens.length != params.amounts.length) revert TokensAndAmountsMismatch();

    PoolId poolId = PoolIdLibrary.toId(params.key);

    uint256 rewardIdx = availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration].length;

    availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration].push(
      Rewards({
        rewardIdx: rewardIdx,
        funder: msg.sender,
        tokens: params.tokens,
        amounts: params.amounts,
        liquidity: params.liquidity
      })
    );

    for (uint256 i = 0; i < params.tokens.length; i++) {
      IERC20(params.tokens[i]).transferFrom(msg.sender, address(this), params.amounts[i]);
    }

    emit AddRewards(abi.encodePacked(params.tokens, params.amounts), params.liquidity, params.lockDuration, msg.sender);
  }

  /// @notice Removes rewards from a specific liquidity pool's tick range.
  /// @param params Parameters containing details of the rewards to remove.
  function removeRewards(RemoveRewardsParams calldata params) external {
    PoolId poolId = PoolIdLibrary.toId(params.key);

    Rewards storage reward = availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration][
      params.idx
    ];

    if (msg.sender != reward.funder) revert NotRewardsFunder();

    delete availableRewards[poolId][params.tickLower][params.tickUpper][params.lockDuration][params.idx];

    for (uint256 i = 0; i < reward.tokens.length; i++) {
      IERC20(reward.tokens[i]).transfer(msg.sender, reward.amounts[i]);
    }

    emit RemoveRewards(
      abi.encodePacked(reward.tokens, reward.amounts),
      reward.liquidity,
      params.lockDuration,
      msg.sender
    );
  }

  /// @notice Locks liquidity in a pool, ensuring the transaction is executed before the deadline.
  /// @param params Parameters for locking the liquidity.
  /// @return liquidityLocked Amount of liquidity successfully locked.
  function lockLiquidity(
    LockLiquidityParams calldata params
  ) external ensure(params.deadline) returns (uint128 liquidityLocked) {
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

    (address[] memory tokens, uint256[] memory calculatedRewards) = _calculateRewardAmount(rewards, liquidityToLock);

    _createLock(params, liquidityToLock, tokens, calculatedRewards);

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

    for (uint256 i = 0; i < tokens.length; i++) {
      IERC20(tokens[i]).transfer(msg.sender, calculatedRewards[i]);
    }

    emit LockLiquidity(params.key, abi.encodePacked(tokens, calculatedRewards), liquidityToLock);

    return liquidityToLock;
  }

  /// @notice Unlocks liquidity from a pool, ensuring the transaction is executed before the deadline.
  /// @param lockId Identifier of the lock to be unlocked.
  /// @param deadline Time by which the transaction must be processed.
  function unlockLiquidity(uint256 lockId, uint256 deadline) external ensure(deadline) {
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

    emit UnlockLiquidity(lockId, msg.sender, lock.liquidity);
  }

  ////////////////////////////////////////////////
  //               HELPER FUNCTIONS             //
  ////////////////////////////////////////////////

  /// @notice Calculates the reward amounts based on the locked liquidity.
  /// @param rewards Details of the rewards for the liquidity lock.
  /// @param liquidityToLock Amount of liquidity being locked.
  /// @return tokens Array of tokens for which rewards will be provided.
  /// @return calculatedRewards Array of calculated reward amounts for each token.
  function _calculateRewardAmount(
    Rewards storage rewards,
    uint128 liquidityToLock
  ) internal returns (address[] memory tokens, uint256[] memory calculatedRewards) {
    uint128 effectiveLiquidity = liquidityToLock < rewards.liquidity ? liquidityToLock : rewards.liquidity;
    uint256 liquidityRewardsRatio = (uint256(effectiveLiquidity) * 1e18) / rewards.liquidity;

    tokens = new address[](rewards.tokens.length);
    calculatedRewards = new uint256[](rewards.tokens.length);

    for (uint256 i = 0; i < rewards.tokens.length; i++) {
      uint256 rewardAmount = (rewards.amounts[i] * liquidityRewardsRatio) / 1e18;
      rewards.amounts[i] -= rewardAmount;

      tokens[i] = rewards.tokens[i];
      calculatedRewards[i] = rewardAmount;
    }

    rewards.liquidity -= effectiveLiquidity;

    return (tokens, calculatedRewards);
  }

  /// @notice Creates a lock of liquidity with associated rewards.
  /// @param params Parameters detailing the lock to be created.
  /// @param liquidity Amount of liquidity to be locked.
  /// @param tokens Array of reward tokens associated with the lock.
  /// @param rewardsAmounts Array of reward amounts corresponding to each token.
  function _createLock(
    LockLiquidityParams calldata params,
    uint128 liquidity,
    address[] memory tokens,
    uint256[] memory rewardsAmounts
  ) internal {
    userLocks[msg.sender].push(
      Lock({
        lockId: userLocks[msg.sender].length,
        lockDate: block.timestamp,
        liquidity: liquidity,
        key: params.key,
        tickLower: params.modifyLiquidityParams.tickLower,
        tickUpper: params.modifyLiquidityParams.tickUpper,
        lockDuration: params.lockDuration,
        unlockedAndWithdrawn: false,
        user: msg.sender,
        tokens: tokens,
        rewardsAmounts: rewardsAmounts
      })
    );

    emit CreateLock(params.key, liquidity, msg.sender, params.lockDuration);
  }

  /// @notice Converts a lock duration enum to seconds.
  /// @param duration Enum representing the duration of the lock.
  /// @return The number of seconds corresponding to the lock duration.
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
