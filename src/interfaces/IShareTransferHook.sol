// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Callback invoked before active shares are minted, burned, or transferred.
/// @dev Implementations may update account checkpoints and may revert to reject an operation.
interface IShareTransferHook {
    function beforeShareTransfer(address from, address to, uint256 amount) external;
}
