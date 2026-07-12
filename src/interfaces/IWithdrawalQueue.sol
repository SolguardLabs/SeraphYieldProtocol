// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { WithdrawalRequest, WithdrawalStatus } from "../types/SeraphTypes.sol";

/// @notice Persistent queue used by the vault for delayed withdrawals.
interface IWithdrawalQueue {
    function vault() external view returns (address);
    function withdrawalDelay() external view returns (uint256);
    function claimWindow() external view returns (uint256);
    function nextRequestId() external view returns (uint256);
    function totalQueuedShares() external view returns (uint256);
    function queuedSharesOf(address owner) external view returns (uint256);

    function enqueue(
        address owner,
        address receiver,
        uint256 shares,
        uint256 assetsAtRequest,
        uint256 minAssets
    ) external returns (uint256 requestId);

    function cancel(uint256 requestId, address caller)
        external
        returns (WithdrawalRequest memory request);

    function consume(uint256 requestId, address caller, uint256 assetsClaimable)
        external
        returns (WithdrawalRequest memory request);

    function request(uint256 requestId) external view returns (WithdrawalRequest memory);
    function statusOf(uint256 requestId) external view returns (WithdrawalStatus);
    function isClaimable(uint256 requestId) external view returns (bool);
    function ownerRequestCount(address owner) external view returns (uint256);
    function ownerRequestAt(address owner, uint256 index) external view returns (uint256);
}
