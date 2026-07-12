// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Policy checks kept separate from vault execution.
interface IRiskController {
    function depositCap() external view returns (uint256);
    function maxQueuedBps() external view returns (uint256);
    function maxUserQueuedBps() external view returns (uint256);
    function minimumActiveShares() external view returns (uint256);
    function minimumIdleBps() external view returns (uint256);
    function maximumReportLossBps() external view returns (uint256);

    function validateDeposit(uint256 grossAssets, uint256 assets) external view;
    function validateRequest(
        uint256 totalSupply,
        uint256 totalLocked,
        uint256 ownerBalance,
        uint256 ownerLocked,
        uint256 shares
    ) external view;
    function validateReport(uint256 debtBefore, uint256 loss) external view;
    function targetIdle(uint256 totalAssets) external view returns (uint256);
}
