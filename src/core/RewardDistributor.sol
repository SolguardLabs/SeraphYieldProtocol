// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IRewardDistributor } from "../interfaces/IRewardDistributor.sol";
import { ISeraphShare } from "../interfaces/ISeraphShare.sol";
import { IShareTransferHook } from "../interfaces/IShareTransferHook.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { ReentrancyGuard } from "../security/ReentrancyGuard.sol";
import { AccountRewardState, RewardState } from "../types/SeraphTypes.sol";

/// @title RewardDistributor
/// @notice Index-based distribution of realized strategy proceeds to active vault shares.
contract RewardDistributor is
    IRewardDistributor,
    IShareTransferHook,
    ProtocolAccess,
    ReentrancyGuard
{
    using SafeTransferLib for IERC20;

    error InvalidAsset();
    error InvalidShare();
    error InvalidVault();
    error InvalidReceiver();
    error CallerNotVault();
    error CallerNotShare();
    error ClaimsPaused();
    error DistributionPaused();
    error RewardFundingIncomplete(uint256 available, uint256 expected);
    error AmountOverflow();

    event RewardNotified(
        uint256 assets, uint256 indexed newIndex, uint256 activeSupply, uint256 carriedAssets
    );
    event AccountCheckpointed(
        address indexed account,
        uint256 activeShares,
        uint256 indexed accountIndex,
        uint256 accruedRewards
    );
    event RewardClaimed(address indexed account, address indexed receiver, uint256 assets);
    event ClaimPauseUpdated(bool paused);
    event DistributionPauseUpdated(bool paused);

    uint256 public constant INDEX_PRECISION = 1e27;

    IERC20 public immutable asset;
    ISeraphShare public immutable share;
    address public immutable vault;

    RewardState private _rewardState;
    mapping(address account => AccountRewardState state) private _accountRewards;

    uint256 public totalRewardsNotified;
    uint256 public totalRewardsClaimed;
    bool public claimsPaused;
    bool public distributionPaused;

    modifier onlyVault() {
        if (msg.sender != vault) revert CallerNotVault();
        _;
    }

    modifier onlyShare() {
        if (msg.sender != address(share)) revert CallerNotShare();
        _;
    }

    constructor(
        address initialGovernor,
        address initialGuardian,
        address asset_,
        address share_,
        address vault_
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        if (asset_ == address(0)) revert InvalidAsset();
        if (share_ == address(0)) revert InvalidShare();
        if (vault_ == address(0)) revert InvalidVault();
        asset = IERC20(asset_);
        share = ISeraphShare(share_);
        vault = vault_;
        _rewardState.lastUpdated = MathLib.toUint40(block.timestamp);
    }

    function rewardIndex() public view returns (uint256) {
        return _rewardState.index;
    }

    function undistributedRewards() public view returns (uint256) {
        return _rewardState.undistributedAssets;
    }

    function accountedRewards() external view returns (uint256) {
        return _rewardState.accountedAssets;
    }

    function lastRewardUpdate() external view returns (uint256) {
        return _rewardState.lastUpdated;
    }

    function rewardState() external view returns (RewardState memory) {
        return _rewardState;
    }

    function accountState(address account) external view returns (AccountRewardState memory) {
        return _accountRewards[account];
    }

    function accountIndex(address account) external view returns (uint256) {
        return _accountRewards[account].index;
    }

    function accruedRewards(address account) external view returns (uint256) {
        return _accountRewards[account].accrued;
    }

    function availableRewards() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function fundedRewardsOutstanding() external view returns (uint256) {
        return MathLib.saturatingSub(totalRewardsNotified, totalRewardsClaimed);
    }

    /// @notice Records an account at the current global reward index.
    function checkpoint(address account) public returns (uint256 accrued) {
        _checkpoint(account);
        return _accountRewards[account].accrued;
    }

    /// @inheritdoc IShareTransferHook
    function beforeShareTransfer(address from, address to, uint256) external onlyShare {
        if (from != address(0)) _checkpoint(from);
        if (to != address(0) && to != from) _checkpoint(to);
    }

    /// @notice Adds a funded reward amount to the active-share accumulator.
    function notifyReward(uint256 assets) external onlyVault {
        if (distributionPaused) revert DistributionPaused();

        uint256 expectedBalance =
            MathLib.saturatingSub(totalRewardsNotified + assets, totalRewardsClaimed);
        uint256 available = asset.balanceOf(address(this));
        if (available < expectedBalance) {
            revert RewardFundingIncomplete(available, expectedBalance);
        }

        totalRewardsNotified += assets;
        _distribute(assets);
    }

    /// @notice Moves carried rounding dust into the index once supply is available.
    function distributeCarry() external {
        if (distributionPaused) revert DistributionPaused();
        _distribute(0);
    }

    function claim(address receiver) external nonReentrant returns (uint256 assets) {
        return _claim(msg.sender, receiver);
    }

    function claimFor(address account, address receiver)
        external
        onlyVault
        nonReentrant
        returns (uint256 assets)
    {
        return _claim(account, receiver);
    }

    function previewClaim(address account) public view returns (uint256 assets) {
        AccountRewardState memory accountReward = _accountRewards[account];
        assets = accountReward.accrued;
        uint256 currentIndex = _rewardState.index;
        if (currentIndex > accountReward.index) {
            assets += MathLib.mulDivDown(
                share.activeBalanceOf(account), currentIndex - accountReward.index, INDEX_PRECISION
            );
        }
    }

    function setClaimsPaused(bool paused) external onlyGovernorOrGuardian {
        claimsPaused = paused;
        emit ClaimPauseUpdated(paused);
    }

    function setDistributionPaused(bool paused) external onlyGovernorOrGuardian {
        distributionPaused = paused;
        emit DistributionPauseUpdated(paused);
    }

    function _checkpoint(address account) internal {
        if (account == address(0)) return;

        AccountRewardState storage accountReward = _accountRewards[account];
        uint256 currentIndex = _rewardState.index;
        uint256 previousIndex = accountReward.index;
        uint256 activeShares = share.activeBalanceOf(account);

        if (currentIndex > previousIndex && activeShares != 0) {
            uint256 newlyAccrued =
                MathLib.mulDivDown(activeShares, currentIndex - previousIndex, INDEX_PRECISION);
            accountReward.accrued += newlyAccrued;
        }

        accountReward.index = currentIndex;
        emit AccountCheckpointed(account, activeShares, currentIndex, accountReward.accrued);
    }

    function _distribute(uint256 newlyFunded) internal {
        uint256 distributable = newlyFunded + _rewardState.undistributedAssets;
        uint256 activeSupply = share.activeSupply();
        _rewardState.lastUpdated = MathLib.toUint40(block.timestamp);

        if (distributable == 0) {
            emit RewardNotified(0, _rewardState.index, activeSupply, 0);
            return;
        }
        if (activeSupply == 0) {
            _rewardState.undistributedAssets = distributable;
            emit RewardNotified(newlyFunded, _rewardState.index, 0, distributable);
            return;
        }

        uint256 indexDelta = MathLib.mulDivDown(distributable, INDEX_PRECISION, activeSupply);
        if (indexDelta == 0) {
            _rewardState.undistributedAssets = distributable;
            emit RewardNotified(newlyFunded, _rewardState.index, activeSupply, distributable);
            return;
        }

        uint256 indexedAssets = MathLib.mulDivDown(activeSupply, indexDelta, INDEX_PRECISION);
        _rewardState.index += indexDelta;
        _rewardState.accountedAssets += indexedAssets;
        _rewardState.undistributedAssets = distributable - indexedAssets;

        emit RewardNotified(
            newlyFunded, _rewardState.index, activeSupply, _rewardState.undistributedAssets
        );
    }

    function _claim(address account, address receiver) internal returns (uint256 assets) {
        if (claimsPaused) revert ClaimsPaused();
        if (receiver == address(0)) revert InvalidReceiver();

        _checkpoint(account);
        AccountRewardState storage accountReward = _accountRewards[account];
        assets = accountReward.accrued;
        if (assets == 0) return 0;

        accountReward.accrued = 0;
        totalRewardsClaimed += assets;
        asset.safeTransfer(receiver, assets);
        emit RewardClaimed(account, receiver, assets);
    }
}
