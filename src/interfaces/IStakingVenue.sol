// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Generic synchronous staking venue consumed by `StakingStrategy`.
/// @dev Implementations can adapt validator staking, liquid-staking pools, or farm contracts. The
///      adapter is responsible for presenting all immediately redeemable stake as asset units.
interface IStakingVenue {
    /// @notice Token accepted by `stake` and returned by `unstake`.
    function stakingToken() external view returns (address);

    /// @notice Incentive token emitted by this venue.
    function rewardToken() external view returns (address);

    /// @notice Receipt units currently owned by `account`.
    function stakedBalance(address account) external view returns (uint256);

    /// @notice Current asset value of receipt units.
    function convertToAssets(uint256 receiptUnits) external view returns (uint256);

    /// @notice Estimate receipt units obtained for an asset deposit.
    function previewStake(uint256 assets) external view returns (uint256);

    /// @notice Estimate assets returned for a receipt-unit redemption.
    function previewUnstake(uint256 receiptUnits) external view returns (uint256);

    /// @notice Maximum assets that can currently be staked for `receiver`.
    function maxStake(address receiver) external view returns (uint256);

    /// @notice Maximum receipt units that can be synchronously unstaked by `owner`.
    function maxUnstake(address owner) external view returns (uint256);

    /// @notice Stake assets and credit receipt units to `receiver`.
    function stake(uint256 assets, address receiver) external returns (uint256 receiptUnits);

    /// @notice Burn receipt units and transfer the resulting assets to `receiver`.
    function unstake(uint256 receiptUnits, address receiver) external returns (uint256 assets);

    /// @notice Claimable incentive balance for an account.
    function pendingRewards(address account) external view returns (uint256);

    /// @notice Claim incentives and transfer them to `receiver`.
    function claimRewards(address receiver) external returns (uint256 rewards);
}
