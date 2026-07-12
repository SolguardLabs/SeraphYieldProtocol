// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IRiskController } from "../interfaces/IRiskController.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { SeraphConstants } from "../types/SeraphTypes.sol";

/// @title RiskController
/// @notice Admission rules and solvency-oriented operating limits for one vault.
contract RiskController is IRiskController, ProtocolAccess {
    error InvalidConfiguration();
    error DepositCapExceeded(uint256 projectedAssets, uint256 cap);
    error QueueCapacityExceeded(uint256 projectedLocked, uint256 maximumLocked);
    error AccountQueueCapacityExceeded(uint256 projectedLocked, uint256 maximumLocked);
    error ActiveSupplyTooLow(uint256 projectedActive, uint256 minimumActive);
    error ReportLossTooLarge(uint256 loss, uint256 maximumLoss);
    error InsufficientShares();

    event RiskConfigurationUpdated(
        uint256 depositCap,
        uint256 maxQueuedBps,
        uint256 maxUserQueuedBps,
        uint256 minimumActiveShares,
        uint256 minimumIdleBps,
        uint256 maximumReportLossBps
    );

    uint256 public depositCap;
    uint256 public maxQueuedBps;
    uint256 public maxUserQueuedBps;
    uint256 public minimumActiveShares;
    uint256 public minimumIdleBps;
    uint256 public maximumReportLossBps;

    constructor(
        address initialGovernor,
        address initialGuardian,
        uint256 depositCap_,
        uint256 maxQueuedBps_,
        uint256 maxUserQueuedBps_,
        uint256 minimumActiveShares_,
        uint256 minimumIdleBps_,
        uint256 maximumReportLossBps_
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        _setConfiguration(
            depositCap_,
            maxQueuedBps_,
            maxUserQueuedBps_,
            minimumActiveShares_,
            minimumIdleBps_,
            maximumReportLossBps_
        );
    }

    function validateDeposit(uint256 grossAssets, uint256 assets) external view {
        if (assets == 0) revert InsufficientShares();
        uint256 projected = grossAssets + assets;
        if (depositCap != 0 && projected > depositCap) {
            revert DepositCapExceeded(projected, depositCap);
        }
    }

    function validateRequest(
        uint256 totalSupply,
        uint256 totalLocked,
        uint256 ownerBalance,
        uint256 ownerLocked,
        uint256 shares
    ) external view {
        if (shares == 0 || shares > ownerBalance - ownerLocked) {
            revert InsufficientShares();
        }

        uint256 projectedLocked = totalLocked + shares;
        uint256 maximumLocked = MathLib.bpsMulDown(totalSupply, maxQueuedBps);
        if (projectedLocked > maximumLocked) {
            revert QueueCapacityExceeded(projectedLocked, maximumLocked);
        }

        uint256 projectedOwnerLocked = ownerLocked + shares;
        uint256 maximumOwnerLocked = MathLib.bpsMulDown(ownerBalance, maxUserQueuedBps);
        if (projectedOwnerLocked > maximumOwnerLocked) {
            revert AccountQueueCapacityExceeded(projectedOwnerLocked, maximumOwnerLocked);
        }

        uint256 projectedActive = totalSupply - projectedLocked;
        if (projectedActive < minimumActiveShares) {
            revert ActiveSupplyTooLow(projectedActive, minimumActiveShares);
        }
    }

    function validateReport(uint256 debtBefore, uint256 loss) external view {
        if (loss == 0) return;
        uint256 maximumLoss = MathLib.bpsMulUp(debtBefore, maximumReportLossBps);
        if (loss > maximumLoss) revert ReportLossTooLarge(loss, maximumLoss);
    }

    function targetIdle(uint256 totalAssets) external view returns (uint256) {
        return MathLib.bpsMulUp(totalAssets, minimumIdleBps);
    }

    function setConfiguration(
        uint256 depositCap_,
        uint256 maxQueuedBps_,
        uint256 maxUserQueuedBps_,
        uint256 minimumActiveShares_,
        uint256 minimumIdleBps_,
        uint256 maximumReportLossBps_
    ) external onlyGovernor {
        _setConfiguration(
            depositCap_,
            maxQueuedBps_,
            maxUserQueuedBps_,
            minimumActiveShares_,
            minimumIdleBps_,
            maximumReportLossBps_
        );
    }

    function setDepositCap(uint256 newDepositCap) external onlyGovernor {
        depositCap = newDepositCap;
        _emitConfiguration();
    }

    function tightenQueueLimit(uint256 newMaxQueuedBps) external onlyGovernorOrGuardian {
        if (newMaxQueuedBps > maxQueuedBps || newMaxQueuedBps >= SeraphConstants.BPS) {
            revert InvalidConfiguration();
        }
        maxQueuedBps = newMaxQueuedBps;
        _emitConfiguration();
    }

    function _setConfiguration(
        uint256 depositCap_,
        uint256 maxQueuedBps_,
        uint256 maxUserQueuedBps_,
        uint256 minimumActiveShares_,
        uint256 minimumIdleBps_,
        uint256 maximumReportLossBps_
    ) internal {
        if (
            maxQueuedBps_ == 0 || maxQueuedBps_ >= SeraphConstants.BPS || maxUserQueuedBps_ == 0
                || maxUserQueuedBps_ > SeraphConstants.BPS || minimumIdleBps_ > 5000
                || maximumReportLossBps_ == 0 || maximumReportLossBps_ > SeraphConstants.BPS
        ) revert InvalidConfiguration();

        depositCap = depositCap_;
        maxQueuedBps = maxQueuedBps_;
        maxUserQueuedBps = maxUserQueuedBps_;
        minimumActiveShares = minimumActiveShares_;
        minimumIdleBps = minimumIdleBps_;
        maximumReportLossBps = maximumReportLossBps_;
        _emitConfiguration();
    }

    function _emitConfiguration() internal {
        emit RiskConfigurationUpdated(
            depositCap,
            maxQueuedBps,
            maxUserQueuedBps,
            minimumActiveShares,
            minimumIdleBps,
            maximumReportLossBps
        );
    }
}
