// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IWithdrawalQueue } from "../interfaces/IWithdrawalQueue.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { WithdrawalRequest, WithdrawalRound, WithdrawalStatus } from "../types/SeraphTypes.sol";

/// @title WithdrawalQueue
/// @notice Stores delayed withdrawal instructions while share ownership remains with users.
contract WithdrawalQueue is IWithdrawalQueue, ProtocolAccess {
    error InvalidVault();
    error InvalidTiming();
    error InvalidRequestSize();
    error InvalidReceiver();
    error CallerNotVault();
    error RequestNotFound(uint256 requestId);
    error RequestNotPending(uint256 requestId);
    error RequestNotOwned(uint256 requestId, address caller);
    error RequestNotReady(uint256 requestId, uint256 claimableAt);
    error RequestWindowClosed(uint256 requestId, uint256 expiresAt);
    error MinimumAssetsNotMet(uint256 assets, uint256 minimumAssets);
    error PaginationOutOfBounds();

    event RequestEnqueued(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assetsAtRequest,
        uint256 minAssets,
        uint256 claimableAt,
        uint256 expiresAt,
        uint256 round
    );
    event RequestCancelled(uint256 indexed requestId, address indexed owner, uint256 shares);
    event RequestConsumed(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assets,
        address executor
    );
    event QueueTimingUpdated(uint256 withdrawalDelay, uint256 claimWindow, uint256 roundDuration);
    event RequestLimitsUpdated(uint256 minimumRequestShares, uint256 maximumRequestShares);

    address public immutable vault;

    uint256 public withdrawalDelay;
    uint256 public claimWindow;
    uint256 public roundDuration;
    uint256 public minimumRequestShares;
    uint256 public maximumRequestShares;
    uint256 public nextRequestId = 1;
    uint256 public totalQueuedShares;

    mapping(uint256 requestId => WithdrawalRequest requestData) private _requests;
    mapping(address owner => uint256 shares) public queuedSharesOf;
    mapping(address owner => uint256[] requestIds) private _ownerRequests;
    mapping(uint256 round => WithdrawalRound data) private _rounds;

    modifier onlyVault() {
        if (msg.sender != vault) revert CallerNotVault();
        _;
    }

    constructor(
        address initialGovernor,
        address initialGuardian,
        address vault_,
        uint256 withdrawalDelay_,
        uint256 claimWindow_,
        uint256 roundDuration_,
        uint256 minimumRequestShares_,
        uint256 maximumRequestShares_
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        if (vault_ == address(0)) revert InvalidVault();
        vault = vault_;
        _setTiming(withdrawalDelay_, claimWindow_, roundDuration_);
        _setRequestLimits(minimumRequestShares_, maximumRequestShares_);
    }

    function enqueue(
        address owner,
        address receiver,
        uint256 shares,
        uint256 assetsAtRequest,
        uint256 minAssets
    ) external onlyVault returns (uint256 requestId) {
        if (owner == address(0) || receiver == address(0)) {
            revert InvalidReceiver();
        }
        if (
            shares < minimumRequestShares
                || (maximumRequestShares != 0 && shares > maximumRequestShares)
        ) revert InvalidRequestSize();

        requestId = nextRequestId++;
        uint256 claimableAt = block.timestamp + withdrawalDelay;
        uint256 expiresAt = claimableAt + claimWindow;
        uint256 round = currentRound();

        WithdrawalRequest storage newRequest = _requests[requestId];
        newRequest.owner = owner;
        newRequest.receiver = receiver;
        newRequest.shares = MathLib.toUint128(shares);
        newRequest.assetsAtRequest = MathLib.toUint128(assetsAtRequest);
        newRequest.minAssets = MathLib.toUint128(minAssets);
        newRequest.requestedAt = MathLib.toUint40(block.timestamp);
        newRequest.claimableAt = MathLib.toUint40(claimableAt);
        newRequest.expiresAt = MathLib.toUint40(expiresAt);
        newRequest.round = MathLib.toUint32(round);
        newRequest.status = WithdrawalStatus.Pending;

        totalQueuedShares += shares;
        queuedSharesOf[owner] += shares;
        _ownerRequests[owner].push(requestId);

        WithdrawalRound storage roundData = _rounds[round];
        if (roundData.openedAt == 0) roundData.openedAt = MathLib.toUint40(block.timestamp);
        roundData.sharesRequested = MathLib.toUint128(uint256(roundData.sharesRequested) + shares);

        emit RequestEnqueued(
            requestId,
            owner,
            receiver,
            shares,
            assetsAtRequest,
            minAssets,
            claimableAt,
            expiresAt,
            round
        );
    }

    function cancel(uint256 requestId, address caller)
        external
        onlyVault
        returns (WithdrawalRequest memory requestData)
    {
        WithdrawalRequest storage stored = _pendingRequest(requestId);
        if (stored.owner != caller) revert RequestNotOwned(requestId, caller);

        stored.status = WithdrawalStatus.Cancelled;
        uint256 shares = stored.shares;
        totalQueuedShares -= shares;
        queuedSharesOf[stored.owner] -= shares;

        requestData = stored;
        emit RequestCancelled(requestId, stored.owner, shares);
    }

    function consume(uint256 requestId, address caller, uint256 assetsClaimable)
        external
        onlyVault
        returns (WithdrawalRequest memory requestData)
    {
        WithdrawalRequest storage stored = _pendingRequest(requestId);
        // Queue maturity is intentionally defined in wall-clock time.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < stored.claimableAt) {
            revert RequestNotReady(requestId, stored.claimableAt);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > stored.expiresAt) {
            revert RequestWindowClosed(requestId, stored.expiresAt);
        }
        if (assetsClaimable < stored.minAssets) {
            revert MinimumAssetsNotMet(assetsClaimable, stored.minAssets);
        }

        stored.assetsClaimable = MathLib.toUint128(assetsClaimable);
        stored.status = WithdrawalStatus.Claimed;

        uint256 shares = stored.shares;
        totalQueuedShares -= shares;
        queuedSharesOf[stored.owner] -= shares;

        WithdrawalRound storage roundData = _rounds[stored.round];
        roundData.sharesProcessed = MathLib.toUint128(uint256(roundData.sharesProcessed) + shares);
        roundData.assetsReserved =
            MathLib.toUint128(uint256(roundData.assetsReserved) + assetsClaimable);
        roundData.assetsClaimed =
            MathLib.toUint128(uint256(roundData.assetsClaimed) + assetsClaimable);
        if (roundData.sharesProcessed == roundData.sharesRequested) {
            roundData.closed = true;
            roundData.processedAt = MathLib.toUint40(block.timestamp);
        }

        requestData = stored;
        emit RequestConsumed(
            requestId, stored.owner, stored.receiver, shares, assetsClaimable, caller
        );
    }

    function request(uint256 requestId) external view returns (WithdrawalRequest memory) {
        WithdrawalRequest memory requestData = _requests[requestId];
        if (requestData.status == WithdrawalStatus.None) revert RequestNotFound(requestId);
        return requestData;
    }

    function statusOf(uint256 requestId) public view returns (WithdrawalStatus) {
        WithdrawalRequest memory requestData = _requests[requestId];
        if (requestData.status == WithdrawalStatus.None) return WithdrawalStatus.None;
        uint256 currentTime = block.timestamp;
        if (
            requestData.status == WithdrawalStatus.Pending && currentTime >= requestData.claimableAt
                && currentTime <= requestData.expiresAt
        ) return WithdrawalStatus.Claimable;
        return requestData.status;
    }

    function isClaimable(uint256 requestId) external view returns (bool) {
        return statusOf(requestId) == WithdrawalStatus.Claimable;
    }

    function currentRound() public view returns (uint256) {
        return block.timestamp / roundDuration;
    }

    function roundInfo(uint256 round) external view returns (WithdrawalRound memory) {
        return _rounds[round];
    }

    function ownerRequestCount(address owner) external view returns (uint256) {
        return _ownerRequests[owner].length;
    }

    function ownerRequestAt(address owner, uint256 index) external view returns (uint256) {
        if (index >= _ownerRequests[owner].length) revert PaginationOutOfBounds();
        return _ownerRequests[owner][index];
    }

    function ownerRequests(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory requestIds)
    {
        uint256 length = _ownerRequests[owner].length;
        if (offset > length) revert PaginationOutOfBounds();
        uint256 end = MathLib.min(offset + limit, length);
        requestIds = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            requestIds[i - offset] = _ownerRequests[owner][i];
        }
    }

    function setTiming(uint256 newWithdrawalDelay, uint256 newClaimWindow, uint256 newRoundDuration)
        external
        onlyGovernor
    {
        _setTiming(newWithdrawalDelay, newClaimWindow, newRoundDuration);
    }

    function setRequestLimits(uint256 newMinimumShares, uint256 newMaximumShares)
        external
        onlyGovernor
    {
        _setRequestLimits(newMinimumShares, newMaximumShares);
    }

    function _pendingRequest(uint256 requestId)
        internal
        view
        returns (WithdrawalRequest storage stored)
    {
        stored = _requests[requestId];
        if (stored.status == WithdrawalStatus.None) revert RequestNotFound(requestId);
        if (stored.status != WithdrawalStatus.Pending) revert RequestNotPending(requestId);
    }

    function _setTiming(uint256 withdrawalDelay_, uint256 claimWindow_, uint256 roundDuration_)
        internal
    {
        if (
            withdrawalDelay_ < 1 hours || withdrawalDelay_ > 30 days || claimWindow_ < 1 hours
                || claimWindow_ > 30 days || roundDuration_ == 0
                || roundDuration_ > withdrawalDelay_
        ) revert InvalidTiming();
        withdrawalDelay = withdrawalDelay_;
        claimWindow = claimWindow_;
        roundDuration = roundDuration_;
        emit QueueTimingUpdated(withdrawalDelay_, claimWindow_, roundDuration_);
    }

    function _setRequestLimits(uint256 minimumShares_, uint256 maximumShares_) internal {
        if (minimumShares_ == 0 || (maximumShares_ != 0 && maximumShares_ < minimumShares_)) {
            revert InvalidRequestSize();
        }
        minimumRequestShares = minimumShares_;
        maximumRequestShares = maximumShares_;
        emit RequestLimitsUpdated(minimumShares_, maximumShares_);
    }
}
