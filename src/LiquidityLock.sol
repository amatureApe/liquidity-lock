// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
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
        uint256 idx; // Index in the array
        address funder;
        uint256 amount;
        uint128 liquidity;
    }

    struct Lock {
        uint256 lockId;
        uint256 lockDate;
        uint256 lockDuration;
        uint128 liquidity;
        address user;
        address rewardToken;
        PoolId poolId;
        int24 lowerTick;
        int24 upperTick;
    }

    event CreateRewards(
        address indexed rewardsToken,
        uint256 indexed amount,
        uint128 indexed liquidity,
        address funder,
        LockDuration lockDuration
    );

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

        uint256 idx = availableRewards[poolId][lowerTick][upperTick][
            lockDuration
        ][rewardToken].length;
        availableRewards[poolId][lowerTick][upperTick][lockDuration][
            rewardToken
        ].push(
                RewardsPerLiquidity({
                    idx: idx,
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
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        LockDuration lockDuration,
        uint256 amountToken0,
        uint256 amountToken1,
        address rewardToken,
        uint256 idx
    ) external returns (bytes4) {
        PoolId poolId = PoolIdLibrary.toId(key);

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        uint128 liquidityToLock = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            amountToken0,
            amountToken1
        );

        require(liquidityToLock > 0, "Cannot lock 0 liquidity");

        RewardsPerLiquidity storage reward = availableRewards[poolId][
            lowerTick
        ][upperTick][lockDuration][rewardToken][idx];

        int128 availableRewardLiquidity = reward.liquidity;

        require(
            availableRewardLiquidity >= liquidityToLock,
            "Not enough rewards available"
        );

        // Calculate the ratio of locked liquidity to available reward liquidity
        uint256 liquidityRewardsRatio = (uint256(liquidityToLock) * 1e18) /
            uint256(availableRewardLiquidity);

        // Calculate the amount of rewardToken to distribute based on the ratio
        uint256 rewardAmount = (reward.amount * liquidityRewardsRatio) / 1e18;

        // Decrease the available amount of rewardToken
        reward.amount -= rewardAmount;
        reward.liquidity -= liquidityToLock;

        uint256 lockId = userLocks[msg.sender].length;

        userLocks[msg.sender].push(
            Lock({
                lockId: lockId,
                lockDate: block.timestamp,
                lockDuration: durationToSeconds(lockDuration),
                liquidity: liquidityToLock,
                user: msg.sender,
                rewardToken: rewardToken,
                poolId: poolId,
                lowerTick: lowerTick,
                upperTick: upperTick
            })
        );

        // Transfer the calculated reward amount to the user
        IERC20(rewardToken).transfer(msg.sender, rewardAmount);

        return 0x150b7a02; // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
    }

    ////////////////////////////////////////////////
    //              HELPER FUNTIONS              //
    ////////////////////////////////////////////////
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
        revert("Invalid duration");
    }
}
