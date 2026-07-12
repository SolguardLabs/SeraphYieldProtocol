// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IStakingVenue } from "../interfaces/IStakingVenue.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { BaseStrategy, IStrategyRewardConverter } from "./BaseStrategy.sol";

/// @notice Seraph adapter for a synchronous staking or liquid-staking venue.
contract StakingStrategy is BaseStrategy {
    using SafeTransferLib for IERC20;

    error InvalidVenue(address venue);
    error InvalidRewardConverter(address converter);
    error StakeReceiptSlippage(uint256 receiptUnits, uint256 minimumUnits);
    error RewardConversionSlippage(uint256 received, uint256 minimum);

    event RewardConverterSet(address indexed previousConverter, address indexed newConverter);
    event RewardConversionSlippageSet(uint16 previousBps, uint16 newBps);
    event RewardsConverted(address indexed rewardToken, uint256 rewardsIn, uint256 assetsOut);
    event EmergencyUnstakeFailed(uint256 receiptUnits);

    IStakingVenue public immutable stakingVenue;
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
        if (venue_ == address(0) || IStakingVenue(venue_).stakingToken() != asset_) {
            revert InvalidVenue(venue_);
        }
        stakingVenue = IStakingVenue(venue_);
        rewardConverter = converter_;
        maxRewardConversionSlippageBps = 300;
    }

    function setRewardConverter(address converter) external onlyGovernor {
        address reward = stakingVenue.rewardToken();
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

    /// @notice Receipt units currently controlled by the adapter.
    function receiptBalance() external view returns (uint256) {
        return stakingVenue.stakedBalance(address(this));
    }

    /// @notice Current asset value of the staked position.
    function deployedAssets() public view returns (uint256) {
        uint256 receipts = stakingVenue.stakedBalance(address(this));
        return receipts == 0 ? 0 : stakingVenue.convertToAssets(receipts);
    }

    function _totalManagedAssets() internal view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 deployed = deployedAssets();
        return idle > type(uint256).max - deployed ? type(uint256).max : idle + deployed;
    }

    function _maxDeployableAssets() internal view override returns (uint256) {
        return stakingVenue.maxStake(address(this));
    }

    function _maxLiquidAssets() internal view override returns (uint256) {
        uint256 receipts = stakingVenue.stakedBalance(address(this));
        uint256 liquidReceipts = stakingVenue.maxUnstake(address(this));
        if (liquidReceipts > receipts) liquidReceipts = receipts;
        return liquidReceipts == 0 ? 0 : stakingVenue.previewUnstake(liquidReceipts);
    }

    function _deployFunds(uint256 assets) internal override {
        if (assets == 0) return;

        IERC20 token = IERC20(asset);
        uint256 receiptsBefore = stakingVenue.stakedBalance(address(this));
        uint256 previewReceipts = stakingVenue.previewStake(assets);
        uint256 minimumReceipts = previewReceipts * (BPS - maxDepositSlippageBps) / BPS;

        token.forceApprove(address(stakingVenue), assets);
        stakingVenue.stake(assets, address(this));
        token.forceApprove(address(stakingVenue), 0);

        uint256 receiptUnits = stakingVenue.stakedBalance(address(this)) - receiptsBefore;
        if (receiptUnits < minimumReceipts) {
            revert StakeReceiptSlippage(receiptUnits, minimumReceipts);
        }
    }

    function _freeFunds(uint256 assets) internal override {
        if (assets == 0) return;

        uint256 receipts = stakingVenue.stakedBalance(address(this));
        if (receipts == 0) return;

        uint256 value = stakingVenue.convertToAssets(receipts);
        if (value == 0) return;

        uint256 receiptUnits;
        if (assets >= value) {
            receiptUnits = receipts;
        } else {
            receiptUnits = MathLib.mulDivUp(assets, receipts, value);
        }

        uint256 maximum = stakingVenue.maxUnstake(address(this));
        if (receiptUnits > maximum) receiptUnits = maximum;
        if (receiptUnits != 0) stakingVenue.unstake(receiptUnits, address(this));
    }

    function _claimRewards() internal override returns (uint256 rewards) {
        rewards = stakingVenue.claimRewards(address(this));
        address reward = stakingVenue.rewardToken();
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
        uint256 receipts = stakingVenue.stakedBalance(address(this));
        if (receipts == 0) return;

        uint256 maximum = stakingVenue.maxUnstake(address(this));
        uint256 exitReceipts = receipts < maximum ? receipts : maximum;
        if (exitReceipts == 0) return;

        try stakingVenue.unstake(exitReceipts, address(this)) returns (uint256) { }
        catch {
            emit EmergencyUnstakeFailed(exitReceipts);
        }
    }
}
