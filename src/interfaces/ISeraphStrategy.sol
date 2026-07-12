// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { StrategyReport, StrategyStatus } from "../types/SeraphTypes.sol";

/// @notice Common interface for strategies managed by a Seraph vault.
interface ISeraphStrategy {
    event StrategyDeposit(uint256 assets, uint256 totalManagedAssets);
    event StrategyWithdrawal(
        address indexed receiver, uint256 requestedAssets, uint256 withdrawnAssets, uint256 loss
    );
    event StrategyReported(uint256 totalAssets, uint256 gain, uint256 loss, uint256 debtPayment);
    event StrategyShutdown();

    /// @notice Underlying ERC-20 deployed by this strategy.
    function asset() external view returns (address);

    /// @notice Vault with exclusive access to capital-moving operations.
    function vault() external view returns (address);

    /// @notice Human-readable identifier for off-chain operators.
    function name() external view returns (string memory);

    /// @notice Current lifecycle status of the strategy.
    function status() external view returns (StrategyStatus);

    /// @notice Best estimate of assets controlled by the strategy.
    function totalAssets() external view returns (uint256);

    /// @notice Additional assets that can currently be accepted.
    function maxDeposit() external view returns (uint256);

    /// @notice Assets that can currently be returned without an asynchronous unwind.
    function maxWithdraw() external view returns (uint256);

    /// @notice Deploy assets supplied by the vault.
    /// @return deployed Assets successfully put to work.
    function deposit(uint256 assets) external returns (uint256 deployed);

    /// @notice Return assets to a receiver chosen by the vault.
    /// @return withdrawn Assets actually transferred.
    /// @return loss Shortfall recognized while satisfying the request.
    function withdraw(uint256 assets, address receiver)
        external
        returns (uint256 withdrawn, uint256 loss);

    /// @notice Realize strategy proceeds and return a fresh accounting report.
    function harvest() external returns (StrategyReport memory report);

    /// @notice Prevent future deposits and begin an orderly unwind.
    function shutdown() external;

    /// @notice Attempt to return all recoverable assets during an emergency.
    function emergencyWithdraw(address receiver) external returns (uint256 withdrawn);
}
