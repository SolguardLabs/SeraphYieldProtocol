// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared constants used throughout the Seraph protocol.
library SeraphConstants {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_STRATEGIES = 16;
    uint256 internal constant MAX_FEE_BPS = 2000;
}

/// @notice Lifecycle of a strategy registered in the protocol.
enum StrategyStatus {
    Inactive,
    Active,
    Paused,
    Retiring
}

/// @notice Lifecycle of an asynchronous withdrawal request.
enum WithdrawalStatus {
    None,
    Pending,
    Claimable,
    Claimed,
    Cancelled
}

/// @notice The operation represented by a rebalance instruction.
enum RebalanceAction {
    Deposit,
    Withdraw
}

/// @notice Static and governance-controlled configuration for one strategy.
/// @dev The compact integer fields are intentionally grouped for efficient storage packing.
struct StrategyConfig {
    address strategy;
    uint128 depositCap;
    uint40 activatedAt;
    uint16 targetBps;
    uint16 maxDeviationBps;
    StrategyStatus status;
}

/// @notice Accounting state maintained by the vault for one strategy.
struct StrategyState {
    uint128 debt;
    uint128 reportedAssets;
    uint128 cumulativeGain;
    uint128 cumulativeLoss;
    uint40 lastReport;
    uint32 reportNonce;
}

/// @notice Result returned by a strategy when it reports to the vault.
struct StrategyReport {
    uint256 totalAssets;
    uint256 gain;
    uint256 loss;
    uint256 debtPayment;
    uint40 timestamp;
}

/// @notice A single asset movement used during a rebalance.
struct RebalanceInstruction {
    address strategy;
    uint256 assets;
    uint256 minAssetsOut;
    RebalanceAction action;
}

/// @notice Persistent information for one queued withdrawal.
struct WithdrawalRequest {
    address owner;
    address receiver;
    uint128 shares;
    uint128 assetsAtRequest;
    uint128 minAssets;
    uint128 assetsClaimable;
    uint40 requestedAt;
    uint40 claimableAt;
    uint40 expiresAt;
    uint32 round;
    WithdrawalStatus status;
}

/// @notice Aggregate state for a withdrawal processing round.
struct WithdrawalRound {
    uint128 sharesRequested;
    uint128 sharesProcessed;
    uint128 assetsReserved;
    uint128 assetsClaimed;
    uint40 openedAt;
    uint40 processedAt;
    bool closed;
}

/// @notice Reward accumulator state used for active share accounting.
struct RewardState {
    uint256 index;
    uint256 accountedAssets;
    uint256 undistributedAssets;
    uint40 lastUpdated;
}

/// @notice Per-account reward checkpoint.
struct AccountRewardState {
    uint256 index;
    uint256 accrued;
}

/// @notice Fee rates controlled by governance.
struct FeeConfig {
    uint16 performanceFeeBps;
    uint16 managementFeeBps;
    uint16 withdrawalFeeBps;
    address recipient;
}

/// @notice Read-only vault accounting snapshot for integrations and keepers.
struct VaultSnapshot {
    uint256 idleAssets;
    uint256 strategyAssets;
    uint256 reservedAssets;
    uint256 activeSupply;
    uint256 lockedSupply;
    uint256 grossAssets;
    uint40 timestamp;
}
