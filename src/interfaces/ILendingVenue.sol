// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-4626-like surface expected by `LendingStrategy`.
/// @dev A venue adapter may wrap a money market whose native API is not ERC-4626. The adapter must
///      express all amounts in units of `asset()` and mint one transferable share balance per
/// lender.
interface ILendingVenue {
    /// @notice Asset supplied to and withdrawn from the lending market.
    function asset() external view returns (address);

    /// @notice Optional reward token paid by the venue.
    /// @dev Returning address(0) means the venue has no separately claimable incentive token.
    function rewardToken() external view returns (address);

    /// @notice Venue shares owned by an account.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Convert venue shares to their current underlying value.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Estimate shares minted for an underlying deposit.
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice Estimate shares burned by an exact-underlying withdrawal.
    function previewWithdraw(uint256 assets) external view returns (uint256);

    /// @notice Maximum additional underlying currently accepted for `receiver`.
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Maximum underlying currently withdrawable by `owner`.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice Supply underlying and mint venue shares to `receiver`.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraw an exact amount of underlying, burning shares owned by `owner`.
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 sharesBurned);

    /// @notice Redeem venue shares and transfer underlying to `receiver`.
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Incentives currently claimable by an account, denominated in `rewardToken()`.
    function pendingRewards(address account) external view returns (uint256);

    /// @notice Claim incentives and send them to `receiver`.
    function claimRewards(address receiver) external returns (uint256 rewards);
}
