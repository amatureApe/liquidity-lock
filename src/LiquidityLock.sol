// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

// Liquidity Lock is a hook that allows users to lock their liquidity for a certain period of time and earn rewards.
// The rewards can be deposited by any user permissionlessly according to their specifications.
// For this prototype, LPs who decide to lock their rewards are immediately paid out the rewards upon locking.

contract LiquidityLock is BaseHook {
    mapping(PoolId poolId => mapping(int24 lowerTick => mapping(int24 upperTick => mapping(LockDuration => mapping(address rewardToken => RewardsPerLiquidity[])))))
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

    struct RewardsPerLiquidity {
        uint256 rewardIdx;
        address funder;
        uint256 amount;
        uint128 liquidity;
    }

    struct Lock {
        uint256 lockId;
        uint256 lockDate;
        LockDuration lockDuration;
        uint128 liquidity;
        address user;
        address rewardToken;
        uint256 rewardAmount;
        PoolKey key;
        int24 lowerTick;
        int24 upperTick;
        bool unlockedAndWithdrawn;
    }

    struct LockLiquidityParams {
        PoolKey key;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        address rewardToken;
        uint256 rewardIdx;
        int24 lowerTick;
        int24 upperTick;
        LockDuration lockDuration;
    }

    ////////////////////////////////////////////////
    //              EVENTS & ERRORS               //
    ////////////////////////////////////////////////

    event CreateRewards(
        address indexed rewardsToken,
        uint256 indexed amount,
        uint128 indexed liquidity,
        address funder,
        LockDuration lockDuration
    );

    error SenderMustBeHook();
    error PoolNotInitialized();
    error NoLiquidityToLock();
    error TooMuchSlippage();
    error CannotUnlockYet(uint256 unlockDate);
    error AlreadyUnlocked();
    error InvalidDuration();

    ////////////////////////////////////////////////
    //                    SETUP                   //
    ////////////////////////////////////////////////

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
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
    ////////////////////////////////////////////////
    //             MUTATIVE FUNCTIONS             //
    ////////////////////////////////////////////////

    function createRewards(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        LockDuration lockDuration,
        address rewardToken,
        uint256 rewardsAmount,
        uint128 liquidity
    ) external {
        PoolId poolId = PoolIdLibrary.toId(key);

        uint256 rewardIdx = availableRewards[poolId][lowerTick][upperTick][
            lockDuration
        ][rewardToken].length;
        availableRewards[poolId][lowerTick][upperTick][lockDuration][
            rewardToken
        ].push(
                RewardsPerLiquidity({
                    rewardIdx: rewardIdx,
                    funder: msg.sender,
                    amount: rewardsAmount,
                    liquidity: liquidity
                })
            );

        IERC20(rewardToken).transferFrom(
            msg.sender,
            address(this),
            rewardsAmount
        );

        emit CreateRewards(
            rewardToken,
            rewardsAmount,
            liquidity,
            msg.sender,
            lockDuration
        );
    }

    function removeRewards(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        LockDuration lockDuration,
        address rewardToken,
        uint256 idx
    ) external {
        PoolId poolId = PoolIdLibrary.toId(key);

        RewardsPerLiquidity storage reward = availableRewards[poolId][
            lowerTick
        ][upperTick][lockDuration][rewardToken][idx];

        require(
            reward.funder == msg.sender,
            "Only the initial funder can remove rewards"
        );

        uint256 rewardAmount = reward.amount;

        delete availableRewards[poolId][lowerTick][upperTick][lockDuration][
            rewardToken
        ][idx];

        IERC20(rewardToken).transfer(msg.sender, rewardAmount);
    }

    function lockLiquidity(
        LockLiquidityParams calldata params
    ) external returns (uint128 liquidityLocked) {
        PoolId poolId = PoolIdLibrary.toId(params.key);
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
            poolManager,
            poolId
        );

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        uint128 liquidityToLock = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.lowerTick),
            TickMath.getSqrtPriceAtTick(params.upperTick),
            params.amount0Desired,
            params.amount1Desired
        );

        if (liquidityToLock <= 0) revert NoLiquidityToLock();

        RewardsPerLiquidity storage rewards = availableRewards[poolId][
            params.lowerTick
        ][params.upperTick][params.lockDuration][params.rewardToken][
            params.rewardIdx
        ];

        uint256 rewardAmount = calculateRewardAmount(rewards, liquidityToLock);

        createLock(params, liquidityToLock, rewardAmount);

        (BalanceDelta addedDelta, ) = poolManager.modifyLiquidity(
            params.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.lowerTick,
                tickUpper: params.upperTick,
                liquidityDelta: int256(uint256(liquidityToLock)),
                salt: 0
            }),
            ""
        );

        if (
            uint128(-addedDelta.amount0()) < params.amount0Min ||
            uint128(-addedDelta.amount1()) < params.amount1Min
        ) {
            revert TooMuchSlippage();
        }

        // Transfer the calculated reward amount to the user
        IERC20(params.rewardToken).transfer(msg.sender, rewardAmount);

        return liquidityToLock;
    }

    function unlockLiquidity(uint256 lockId) external {
        Lock storage lock = userLocks[msg.sender][lockId];

        if (
            block.timestamp <
            lock.lockDate + durationToSeconds(lock.lockDuration)
        )
            revert CannotUnlockYet(
                lock.lockDate + durationToSeconds(lock.lockDuration)
            );

        if (lock.unlockedAndWithdrawn) revert AlreadyUnlocked();

        lock.unlockedAndWithdrawn = true;

        poolManager.modifyLiquidity(
            lock.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lock.lowerTick,
                tickUpper: lock.upperTick,
                liquidityDelta: -int256(uint256(lock.liquidity)),
                salt: 0
            }),
            ""
        );
    }

    ////////////////////////////////////////////////
    //              HELPER FUNTIONS              //
    ////////////////////////////////////////////////
    function calculateRewardAmount(
        RewardsPerLiquidity storage rewards,
        uint128 liquidityToLock
    ) private returns (uint256 rewardAmount) {
        uint128 effectiveLiquidity = liquidityToLock < rewards.liquidity
            ? liquidityToLock
            : rewards.liquidity;

        uint256 liquidityRewardsRatio = (uint256(effectiveLiquidity) * 1e18) /
            rewards.liquidity;
        rewardAmount = (rewards.amount * liquidityRewardsRatio) / 1e18;
        rewards.amount -= rewardAmount;
        rewards.liquidity -= effectiveLiquidity;

        return rewardAmount;
    }

    function createLock(
        LockLiquidityParams calldata params,
        uint128 liquidity,
        uint256 rewardAmount
    ) private {
        Lock memory newLock = Lock({
            lockId: userLocks[msg.sender].length,
            lockDate: block.timestamp,
            lockDuration: params.lockDuration,
            liquidity: liquidity,
            user: msg.sender,
            rewardToken: params.rewardToken,
            rewardAmount: rewardAmount,
            key: params.key,
            lowerTick: params.lowerTick,
            upperTick: params.upperTick,
            unlockedAndWithdrawn: false
        });

        userLocks[msg.sender].push(newLock);
    }

    function durationToSeconds(
        LockDuration duration
    ) public pure returns (uint256) {
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
