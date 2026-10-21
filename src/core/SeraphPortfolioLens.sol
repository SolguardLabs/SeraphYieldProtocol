// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SeraphVault } from "./SeraphVault.sol";
import { StrategyRouter } from "./StrategyRouter.sol";
import { WithdrawalQueue } from "./WithdrawalQueue.sol";
import { SeraphShare } from "../token/SeraphShare.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { StrategyConfig, StrategyState } from "../types/SeraphTypes.sol";

/// @notice Read-only operational measurements for vault liquidity and strategy debt.
contract SeraphPortfolioLens {
    uint256 private constant BPS = 10_000;

    error InvalidVault();
    error InvalidBasisPoints(uint256 value);

    struct PortfolioSnapshot {
        uint256 totalAssets;
        uint256 idleAssets;
        uint256 strategyDebt;
        uint256 totalShares;
        uint256 activeShares;
        uint256 queuedShares;
        uint256 queuedAssetEstimate;
        uint256 idleCoverageBps;
        uint256 debtShareBps;
        uint256 lastHarvest;
    }

    struct StrategyExposure {
        address strategy;
        uint256 debt;
        uint256 depositCap;
        uint256 targetBps;
        uint256 actualDebtBps;
        uint256 lastReport;
    }

    struct StressEstimate {
        uint256 assetsAfterLoss;
        uint256 requestedRedemption;
        uint256 idleLiquidityGap;
        uint256 totalAssetGap;
    }

    SeraphVault public immutable vault;

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidVault();
        vault = SeraphVault(vault_);
    }

    function snapshot() external view returns (PortfolioSnapshot memory result) {
        SeraphShare share = SeraphShare(address(vault.share()));
        WithdrawalQueue queue = WithdrawalQueue(address(vault.withdrawalQueue()));
        StrategyRouter router = StrategyRouter(address(vault.strategyRouter()));

        result.totalAssets = vault.totalAssets();
        result.idleAssets = vault.idleAssets();
        result.strategyDebt = router.totalDebt();
        result.totalShares = share.totalSupply();
        result.activeShares = share.activeSupply();
        result.queuedShares = queue.totalQueuedShares();
        result.queuedAssetEstimate = vault.previewRedeem(result.queuedShares);
        result.lastHarvest = vault.lastHarvest();

        if (result.queuedAssetEstimate != 0) {
            result.idleCoverageBps =
                MathLib.mulDivDown(result.idleAssets, BPS, result.queuedAssetEstimate);
        }
        if (result.totalAssets != 0) {
            result.debtShareBps = MathLib.mulDivDown(result.strategyDebt, BPS, result.totalAssets);
        }
    }

    function strategies() external view returns (StrategyExposure[] memory exposures) {
        StrategyRouter router = StrategyRouter(address(vault.strategyRouter()));
        uint256 count = router.strategyCount();
        uint256 totalDebt = router.totalDebt();
        exposures = new StrategyExposure[](count);
        for (uint256 i; i < count; ++i) {
            address strategy = router.strategyAt(i);
            StrategyConfig memory config = router.strategyConfig(strategy);
            StrategyState memory state = router.strategyState(strategy);
            exposures[i] = StrategyExposure({
                strategy: strategy,
                debt: state.debt,
                depositCap: config.depositCap,
                targetBps: config.targetBps,
                actualDebtBps: totalDebt == 0 ? 0 : MathLib.mulDivDown(state.debt, BPS, totalDebt),
                lastReport: state.lastReport
            });
        }
    }

    /// @notice Deterministic accounting stress; it does not estimate strategy withdrawal speed.
    function stress(uint16 strategyLossBps, uint16 redemptionBps)
        external
        view
        returns (StressEstimate memory result)
    {
        if (strategyLossBps > BPS) revert InvalidBasisPoints(strategyLossBps);
        if (redemptionBps > BPS) revert InvalidBasisPoints(redemptionBps);

        uint256 idle = vault.idleAssets();
        uint256 debt = vault.strategyAssets();
        uint256 total = idle + debt;
        uint256 strategyLoss = MathLib.mulDivDown(debt, strategyLossBps, BPS);
        result.assetsAfterLoss = total - strategyLoss;
        result.requestedRedemption = MathLib.mulDivDown(total, redemptionBps, BPS);
        result.idleLiquidityGap = MathLib.saturatingSub(result.requestedRedemption, idle);
        result.totalAssetGap =
            MathLib.saturatingSub(result.requestedRedemption, result.assetsAfterLoss);
    }
}
