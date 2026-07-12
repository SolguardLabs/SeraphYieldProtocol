// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ILendingVenue } from "../interfaces/ILendingVenue.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { BaseStrategy, IStrategyRewardConverter } from "./BaseStrategy.sol";

/// @notice Seraph adapter for an ERC-4626-like overcollateralized lending venue.
contract LendingStrategy is BaseStrategy {
    using SafeTransferLib for IERC20;

    error InvalidVenue(address venue);
    error InvalidRewardConverter(address converter);
    error VenueShareSlippage(uint256 sharesReceived, uint256 minimumShares);
    error RewardConversionSlippage(uint256 received, uint256 minimum);

    event RewardConverterSet(address indexed previousConverter, address indexed newConverter);
    event RewardConversionSlippageSet(uint16 previousBps, uint16 newBps);
    event RewardsConverted(address indexed rewardToken, uint256 rewardsIn, uint256 assetsOut);
    event EmergencyRedeemFailed(uint256 shares);

    ILendingVenue public immutable lendingVenue;
    address public rewardConverter;
    uint16 public maxRewardConversionSlippageBps;

    constructor(
        address asset_,
        address vault_,
        address venue_,
        address converter_,
        string memory name_,
        address initialGovernor,
        address initialGuardian
    ) BaseStrategy(asset_, vault_, name_, initialGovernor, initialGuardian) {
        if (venue_ == address(0) || ILendingVenue(venue_).asset() != asset_) {
            revert InvalidVenue(venue_);
        }
        lendingVenue = ILendingVenue(venue_);
        rewardConverter = converter_;
        maxRewardConversionSlippageBps = 300;
    }

    /// @notice Update the allowlisted conversion adapter for non-underlying incentives.
    /// @dev Governance is expected to verify the converter's routes and oracle assumptions.
    function setRewardConverter(address converter) external onlyGovernor {
        address reward = lendingVenue.rewardToken();
        if (converter == address(0) && reward != address(0) && reward != asset) {
            uint256 rewardBalance = IERC20(reward).balanceOf(address(this));
            if (rewardBalance != 0) revert InvalidRewardConverter(converter);
        }
        address previous = rewardConverter;
        rewardConverter = converter;
        emit RewardConverterSet(previous, converter);
    }

    function setRewardConversionSlippage(uint16 newSlippageBps) external onlyGovernor {
        if (newSlippageBps > 2000) revert InvalidBps(newSlippageBps);
        uint16 previous = maxRewardConversionSlippageBps;
        maxRewardConversionSlippageBps = newSlippageBps;
        emit RewardConversionSlippageSet(previous, newSlippageBps);
    }

    /// @notice Current lending shares held by this adapter.
    function venueShares() external view returns (uint256) {
        return lendingVenue.balanceOf(address(this));
    }

    /// @notice Asset value currently deployed in the lending venue.
    function deployedAssets() public view returns (uint256) {
        uint256 shares = lendingVenue.balanceOf(address(this));
        return shares == 0 ? 0 : lendingVenue.convertToAssets(shares);
    }

    function _totalManagedAssets() internal view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 deployed = deployedAssets();
        return idle > type(uint256).max - deployed ? type(uint256).max : idle + deployed;
    }

    function _maxDeployableAssets() internal view override returns (uint256) {
        return lendingVenue.maxDeposit(address(this));
    }

    function _maxLiquidAssets() internal view override returns (uint256) {
        uint256 venueMaximum = lendingVenue.maxWithdraw(address(this));
        uint256 deployed = deployedAssets();
        return venueMaximum < deployed ? venueMaximum : deployed;
    }

    function _deployFunds(uint256 assets) internal override {
        if (assets == 0) return;

        IERC20 token = IERC20(asset);
        uint256 sharesBefore = lendingVenue.balanceOf(address(this));
        uint256 previewShares = lendingVenue.previewDeposit(assets);
        uint256 minimumShares = previewShares * (BPS - maxDepositSlippageBps) / BPS;

        token.forceApprove(address(lendingVenue), assets);
        lendingVenue.deposit(assets, address(this));
        token.forceApprove(address(lendingVenue), 0);

        uint256 sharesReceived = lendingVenue.balanceOf(address(this)) - sharesBefore;
        if (sharesReceived < minimumShares) {
            revert VenueShareSlippage(sharesReceived, minimumShares);
        }
    }

    function _freeFunds(uint256 assets) internal override {
        if (assets == 0) return;
        uint256 liquid = lendingVenue.maxWithdraw(address(this));
        uint256 requested = assets < liquid ? assets : liquid;
        if (requested == 0) return;
        lendingVenue.withdraw(requested, address(this), address(this));
    }

    function _claimRewards() internal override returns (uint256 rewards) {
        rewards = lendingVenue.claimRewards(address(this));
        address reward = lendingVenue.rewardToken();
        if (reward == address(0) || reward == asset) return rewards;

        uint256 rewardBalance = IERC20(reward).balanceOf(address(this));
        if (rewardBalance == 0) return rewards;

        address converter = rewardConverter;
        if (converter == address(0)) revert InvalidRewardConverter(converter);

        uint256 quote = IStrategyRewardConverter(converter).quote(reward, asset, rewardBalance);
        uint256 minimum = quote * (BPS - maxRewardConversionSlippageBps) / BPS;
        IERC20 rewardToken = IERC20(reward);
        IERC20 underlying = IERC20(asset);
        uint256 assetBalanceBefore = underlying.balanceOf(address(this));

        rewardToken.forceApprove(converter, rewardBalance);
        IStrategyRewardConverter(converter)
            .convert(reward, asset, rewardBalance, minimum, address(this));
        rewardToken.forceApprove(converter, 0);

        uint256 assetsOut = underlying.balanceOf(address(this)) - assetBalanceBefore;
        if (assetsOut < minimum) revert RewardConversionSlippage(assetsOut, minimum);
        emit RewardsConverted(reward, rewardBalance, assetsOut);
    }

    function _exitPosition() internal override {
        uint256 shares = lendingVenue.balanceOf(address(this));
        if (shares == 0) return;

        uint256 liquid = lendingVenue.maxWithdraw(address(this));
        uint256 positionValue = lendingVenue.convertToAssets(shares);
        if (liquid < positionValue) {
            if (liquid == 0) {
                emit EmergencyRedeemFailed(shares);
                return;
            }
            try lendingVenue.withdraw(liquid, address(this), address(this)) returns (uint256) { }
            catch {
                emit EmergencyRedeemFailed(shares);
            }
            return;
        }

        try lendingVenue.redeem(shares, address(this), address(this)) returns (uint256) { }
        catch {
            emit EmergencyRedeemFailed(shares);
        }
    }
}
