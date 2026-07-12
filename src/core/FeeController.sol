// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IFeeController } from "../interfaces/IFeeController.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { FeeConfig, SeraphConstants } from "../types/SeraphTypes.sol";

/// @title FeeController
/// @notice Central fee policy shared by vault deposits, reports and withdrawals.
contract FeeController is IFeeController, ProtocolAccess {
    error InvalidVault();
    error InvalidRecipient();
    error FeeRateTooHigh();
    error CallerNotVault();

    event FeeConfigurationUpdated(
        uint256 performanceFeeBps,
        uint256 managementFeeBps,
        uint256 withdrawalFeeBps,
        address indexed recipient
    );
    event ManagementFeeCheckpoint(uint256 indexed timestamp, uint256 assets, uint256 feeAssets);

    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2000;
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500;
    uint256 public constant MAX_WITHDRAWAL_FEE_BPS = 200;
    uint256 public constant YEAR = 365 days;

    address public immutable vault;
    FeeConfig private _feeConfig;
    uint40 public lastManagementCheckpoint;

    modifier onlyVault() {
        if (msg.sender != vault) revert CallerNotVault();
        _;
    }

    constructor(
        address initialGovernor,
        address initialGuardian,
        address vault_,
        FeeConfig memory initialConfig
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        if (vault_ == address(0)) revert InvalidVault();
        vault = vault_;
        _validate(initialConfig);
        _feeConfig = initialConfig;
        lastManagementCheckpoint = uint40(block.timestamp);
        emit FeeConfigurationUpdated(
            initialConfig.performanceFeeBps,
            initialConfig.managementFeeBps,
            initialConfig.withdrawalFeeBps,
            initialConfig.recipient
        );
    }

    function feeConfig() external view returns (FeeConfig memory) {
        return _feeConfig;
    }

    function recipient() external view returns (address) {
        return _feeConfig.recipient;
    }

    function performanceFee(uint256 gain) public view returns (uint256) {
        return MathLib.bpsMulDown(gain, _feeConfig.performanceFeeBps);
    }

    function withdrawalFee(uint256 assets) public view returns (uint256) {
        return MathLib.bpsMulDown(assets, _feeConfig.withdrawalFeeBps);
    }

    function managementFee(uint256 totalAssets) public view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(lastManagementCheckpoint);
        if (elapsed == 0 || totalAssets == 0 || _feeConfig.managementFeeBps == 0) return 0;

        uint256 annualFee = MathLib.bpsMulDown(totalAssets, _feeConfig.managementFeeBps);
        return MathLib.mulDivDown(annualFee, elapsed, YEAR);
    }

    function checkpointManagementFee(uint256 totalAssets)
        external
        onlyVault
        returns (uint256 feeAssets)
    {
        feeAssets = managementFee(totalAssets);
        lastManagementCheckpoint = uint40(block.timestamp);
        emit ManagementFeeCheckpoint(block.timestamp, totalAssets, feeAssets);
    }

    function setFeeConfig(FeeConfig calldata newConfig) external onlyGovernor {
        _validate(newConfig);
        _feeConfig = newConfig;
        emit FeeConfigurationUpdated(
            newConfig.performanceFeeBps,
            newConfig.managementFeeBps,
            newConfig.withdrawalFeeBps,
            newConfig.recipient
        );
    }

    function setRecipient(address newRecipient) external onlyGovernor {
        if (newRecipient == address(0)) revert InvalidRecipient();
        _feeConfig.recipient = newRecipient;
        emit FeeConfigurationUpdated(
            _feeConfig.performanceFeeBps,
            _feeConfig.managementFeeBps,
            _feeConfig.withdrawalFeeBps,
            newRecipient
        );
    }

    function _validate(FeeConfig memory config) internal pure {
        if (config.recipient == address(0)) revert InvalidRecipient();
        if (
            config.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS
                || config.managementFeeBps > MAX_MANAGEMENT_FEE_BPS
                || config.withdrawalFeeBps > MAX_WITHDRAWAL_FEE_BPS
                || config.performanceFeeBps > SeraphConstants.MAX_FEE_BPS
        ) revert FeeRateTooHigh();
    }
}
