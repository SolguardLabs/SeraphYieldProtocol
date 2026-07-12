// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    SeraphConstants,
    StrategyConfig,
    StrategyState,
    StrategyStatus,
    RebalanceAction
} from "../types/SeraphTypes.sol";
import { MathLib } from "./MathLib.sol";

/// @notice Pure allocation calculations shared by vaults, routers, and keeper tooling.
library AllocationLib {
    error EmptyAllocation();
    error TooManyStrategies(uint256 supplied, uint256 maximum);
    error ZeroStrategy(uint256 index);
    error DuplicateStrategy(address strategy);
    error InvalidTargetBps(address strategy, uint256 targetBps);
    error InvalidDeviationBps(address strategy, uint256 deviationBps);
    error DisabledStrategyHasTarget(address strategy, uint256 targetBps);
    error InvalidTotalTargetBps(uint256 actual, uint256 expected);
    error ArrayLengthMismatch();

    struct Bounds {
        uint256 target;
        uint256 lower;
        uint256 upper;
    }

    /// @notice Validates a complete allocation set and returns its target weight sum.
    function validate(StrategyConfig[] memory configs) internal pure returns (uint256 totalBps) {
        uint256 length = configs.length;
        if (length == 0) revert EmptyAllocation();
        if (length > SeraphConstants.MAX_STRATEGIES) {
            revert TooManyStrategies(length, SeraphConstants.MAX_STRATEGIES);
        }

        for (uint256 i; i < length; ++i) {
            StrategyConfig memory config = configs[i];
            validateConfig(config, i);

            for (uint256 j; j < i; ++j) {
                if (configs[j].strategy == config.strategy) {
                    revert DuplicateStrategy(config.strategy);
                }
            }

            if (_participatesInAllocation(config.status)) {
                totalBps += config.targetBps;
            } else if (config.targetBps != 0) {
                revert DisabledStrategyHasTarget(config.strategy, config.targetBps);
            }
        }

        if (totalBps != SeraphConstants.BPS) {
            revert InvalidTotalTargetBps(totalBps, SeraphConstants.BPS);
        }
    }

    function validateConfig(StrategyConfig memory config, uint256 index) internal pure {
        if (config.strategy == address(0)) revert ZeroStrategy(index);
        if (config.targetBps > SeraphConstants.BPS) {
            revert InvalidTargetBps(config.strategy, config.targetBps);
        }
        if (config.maxDeviationBps > SeraphConstants.BPS) {
            revert InvalidDeviationBps(config.strategy, config.maxDeviationBps);
        }
    }

    function targetAssets(StrategyConfig memory config, uint256 allocatableAssets)
        internal
        pure
        returns (uint256 target)
    {
        if (!_participatesInAllocation(config.status)) return 0;
        target = MathLib.bpsMulDown(allocatableAssets, config.targetBps);
        if (config.depositCap != 0) target = MathLib.min(target, config.depositCap);
    }

    function allocationBounds(StrategyConfig memory config, uint256 allocatableAssets)
        internal
        pure
        returns (Bounds memory bounds)
    {
        bounds.target = targetAssets(config, allocatableAssets);
        if (bounds.target == 0) return bounds;

        uint256 deviation = MathLib.bpsMulDown(allocatableAssets, config.maxDeviationBps);
        bounds.lower = MathLib.saturatingSub(bounds.target, deviation);
        bounds.upper = bounds.target + deviation;

        if (config.depositCap != 0) {
            bounds.upper = MathLib.min(bounds.upper, config.depositCap);
        }
    }

    function currentWeightBps(uint256 strategyAssets, uint256 allocatableAssets)
        internal
        pure
        returns (uint256)
    {
        if (allocatableAssets == 0) return 0;
        return MathLib.mulDivDown(strategyAssets, SeraphConstants.BPS, allocatableAssets);
    }

    function deviationBps(
        StrategyConfig memory config,
        uint256 strategyAssets,
        uint256 allocatableAssets
    ) internal pure returns (uint256) {
        uint256 currentBps = currentWeightBps(strategyAssets, allocatableAssets);
        return MathLib.absDiff(currentBps, config.targetBps);
    }

    function isWithinBounds(
        StrategyConfig memory config,
        uint256 strategyAssets,
        uint256 allocatableAssets
    ) internal pure returns (bool) {
        Bounds memory bounds = allocationBounds(config, allocatableAssets);
        return strategyAssets >= bounds.lower && strategyAssets <= bounds.upper;
    }

    function depositCapacity(StrategyConfig memory config, uint256 strategyAssets)
        internal
        pure
        returns (uint256)
    {
        if (!canDeposit(config)) return 0;
        if (config.depositCap == 0) return type(uint256).max;
        return MathLib.saturatingSub(config.depositCap, strategyAssets);
    }

    function depositShortfall(
        StrategyConfig memory config,
        uint256 strategyAssets,
        uint256 allocatableAssets
    ) internal pure returns (uint256) {
        if (!canDeposit(config)) return 0;
        uint256 target = targetAssets(config, allocatableAssets);
        return MathLib.min(
            MathLib.saturatingSub(target, strategyAssets), depositCapacity(config, strategyAssets)
        );
    }

    function withdrawExcess(
        StrategyConfig memory config,
        uint256 strategyAssets,
        uint256 allocatableAssets
    ) internal pure returns (uint256) {
        uint256 target = targetAssets(config, allocatableAssets);
        return MathLib.saturatingSub(strategyAssets, target);
    }

    /// @notice Returns the movement needed to return a strategy to its target.
    function rebalanceDelta(
        StrategyConfig memory config,
        uint256 strategyAssets,
        uint256 allocatableAssets
    ) internal pure returns (RebalanceAction action, uint256 assets) {
        uint256 target = targetAssets(config, allocatableAssets);
        if (strategyAssets > target) {
            return (RebalanceAction.Withdraw, strategyAssets - target);
        }
        return (
            RebalanceAction.Deposit,
            MathLib.min(target - strategyAssets, depositCapacity(config, strategyAssets))
        );
    }

    function buildTargets(StrategyConfig[] memory configs, uint256 allocatableAssets)
        internal
        pure
        returns (uint256[] memory targets)
    {
        targets = new uint256[](configs.length);
        for (uint256 i; i < configs.length; ++i) {
            targets[i] = targetAssets(configs[i], allocatableAssets);
        }
    }

    function totalReportedAssets(StrategyState[] memory states)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i; i < states.length; ++i) {
            total += states[i].reportedAssets;
        }
    }

    /// @notice Finds the strategy with the largest absolute deposit shortfall.
    function largestUnderweight(
        StrategyConfig[] memory configs,
        uint256[] memory currentAssets,
        uint256 allocatableAssets
    ) internal pure returns (uint256 index, uint256 shortfall) {
        if (configs.length != currentAssets.length) {
            revert ArrayLengthMismatch();
        }
        index = type(uint256).max;

        for (uint256 i; i < configs.length; ++i) {
            uint256 candidate = depositShortfall(configs[i], currentAssets[i], allocatableAssets);
            if (candidate > shortfall) {
                index = i;
                shortfall = candidate;
            }
        }
    }

    /// @notice Finds the strategy with the largest absolute withdrawal excess.
    function largestOverweight(
        StrategyConfig[] memory configs,
        uint256[] memory currentAssets,
        uint256 allocatableAssets
    ) internal pure returns (uint256 index, uint256 excess) {
        if (configs.length != currentAssets.length) {
            revert ArrayLengthMismatch();
        }
        index = type(uint256).max;

        for (uint256 i; i < configs.length; ++i) {
            uint256 candidate = withdrawExcess(configs[i], currentAssets[i], allocatableAssets);
            if (candidate > excess) {
                index = i;
                excess = candidate;
            }
        }
    }

    function findStrategy(StrategyConfig[] memory configs, address strategy)
        internal
        pure
        returns (bool found, uint256 index)
    {
        for (uint256 i; i < configs.length; ++i) {
            if (configs[i].strategy == strategy) return (true, i);
        }
    }

    function canDeposit(StrategyConfig memory config) internal pure returns (bool) {
        return config.status == StrategyStatus.Active && config.targetBps != 0;
    }

    function canWithdraw(StrategyConfig memory config) internal pure returns (bool) {
        return config.status != StrategyStatus.Inactive;
    }

    function isRetiring(StrategyConfig memory config) internal pure returns (bool) {
        return config.status == StrategyStatus.Retiring;
    }

    function _participatesInAllocation(StrategyStatus status) private pure returns (bool) {
        return status == StrategyStatus.Active || status == StrategyStatus.Paused;
    }
}
