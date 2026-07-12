// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Active-share reward accounting and claims.
interface IRewardDistributor {
    function rewardIndex() external view returns (uint256);
    function totalRewardsNotified() external view returns (uint256);
    function totalRewardsClaimed() external view returns (uint256);
    function undistributedRewards() external view returns (uint256);
    function accruedRewards(address account) external view returns (uint256);
    function accountIndex(address account) external view returns (uint256);

    function checkpoint(address account) external returns (uint256 accrued);
    function notifyReward(uint256 assets) external;
    function claim(address receiver) external returns (uint256 assets);
    function claimFor(address account, address receiver) external returns (uint256 assets);
    function previewClaim(address account) external view returns (uint256 assets);
}
