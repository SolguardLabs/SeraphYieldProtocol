// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ISeraphStrategy } from "../interfaces/ISeraphStrategy.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { StrategyReport, StrategyStatus } from "../types/SeraphTypes.sol";

/// @notice Optional exchange adapter used when a venue pays rewards in a non-underlying token.
interface IStrategyRewardConverter {
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    function convert(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256 amountOut);
}

/// @notice Accounting and access-control foundation for synchronous Seraph strategies.
/// @dev Derived adapters only implement venue-specific valuation and capital movement. Deposits,
///      withdrawals, loss checks, harvest baselines, and lifecycle changes are centralized here so
///      all strategies report using identical semantics.
abstract contract BaseStrategy is ISeraphStrategy, ProtocolAccess {
    using SafeTransferLib for IERC20;

    uint256 internal constant BPS = 10_000;

    error OnlyVault(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidBps(uint256 bps);
    error InvalidStatus(StrategyStatus current);
    error DepositCapacityExceeded(uint256 requested, uint256 available);
    error InsufficientDeployment(uint256 received, uint256 deployed, uint256 minimum);
    error WithdrawalLossExceeded(uint256 loss, uint256 maximum);
    error HarvestIsPaused();
    error AssetRescueForbidden();
    error AdapterOverstatedAssets(uint256 beforeAssets, uint256 afterAssets);
    error ReentrantStrategyCall();

    event StrategyPaused(address indexed caller);
    event StrategyResumed(address indexed caller);
    event HarvestPauseSet(bool paused);
    event DepositLimitSet(uint256 previousLimit, uint256 newLimit);
    event SlippageLimitsSet(uint16 depositSlippageBps, uint16 withdrawalLossBps);
    event GainRealizationSet(bool enabled);
    event RewardsClaimed(uint256 rewardAmount);
    event EmergencyWithdrawal(address indexed receiver, uint256 withdrawn, uint256 remainingAssets);
    event TokenRescued(address indexed token, address indexed receiver, uint256 amount);

    address public immutable override asset;
    address public immutable override vault;
    string public override name;

    StrategyStatus public override status;
    uint256 public depositLimit;
    uint256 public accountedAssets;
    uint40 public lastReport;
    uint16 public maxDepositSlippageBps;
    uint16 public maxWithdrawalLossBps;
    bool public harvestPaused;
    bool public realizeGains;

    uint256 private _entered;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert ReentrantStrategyCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(
        address asset_,
        address vault_,
        string memory name_,
        address initialGovernor,
        address initialGuardian
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        if (asset_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }

        asset = asset_;
        vault = vault_;
        name = name_;
        status = StrategyStatus.Active;
        depositLimit = type(uint256).max;
        maxDepositSlippageBps = 50;
        maxWithdrawalLossBps = 100;
        realizeGains = true;
        lastReport = uint40(block.timestamp);
        _entered = 1;
    }

    /// @inheritdoc ISeraphStrategy
    function totalAssets() public view override returns (uint256) {
        return _totalManagedAssets();
    }

    /// @inheritdoc ISeraphStrategy
    function maxDeposit() public view override returns (uint256) {
        if (status != StrategyStatus.Active) return 0;

        uint256 managed = _totalManagedAssets();
        if (managed >= depositLimit) return 0;

        uint256 remainingLimit = depositLimit - managed;
        uint256 venueCapacity = _maxDeployableAssets();
        return venueCapacity < remainingLimit ? venueCapacity : remainingLimit;
    }

    /// @inheritdoc ISeraphStrategy
    function maxWithdraw() public view override returns (uint256) {
        uint256 managed = _totalManagedAssets();
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 venueLiquidity = _maxLiquidAssets();
        uint256 liquid =
            idle > type(uint256).max - venueLiquidity ? type(uint256).max : idle + venueLiquidity;
        return liquid < managed ? liquid : managed;
    }

    /// @inheritdoc ISeraphStrategy
    function deposit(uint256 assets)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 deployed)
    {
        if (status != StrategyStatus.Active) revert InvalidStatus(status);
        if (assets == 0) revert ZeroAmount();

        uint256 capacity = maxDeposit();
        if (assets > capacity) revert DepositCapacityExceeded(assets, capacity);

        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 totalBefore = _totalManagedAssets();
        token.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        _deployFunds(received);
        uint256 totalAfter = _totalManagedAssets();
        if (totalAfter < totalBefore) {
            revert AdapterOverstatedAssets(totalBefore, totalAfter);
        }

        deployed = totalAfter - totalBefore;
        uint256 minimum = received * (BPS - maxDepositSlippageBps) / BPS;
        if (deployed < minimum) revert InsufficientDeployment(received, deployed, minimum);

        accountedAssets += deployed;
        emit StrategyDeposit(deployed, totalAfter);
    }

    /// @inheritdoc ISeraphStrategy
    function withdraw(uint256 assets, address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 withdrawn, uint256 loss)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();

        IERC20 token = IERC20(asset);
        uint256 totalBefore = _totalManagedAssets();
        uint256 idle = token.balanceOf(address(this));
        if (idle < assets) _freeFunds(assets - idle);

        uint256 available = token.balanceOf(address(this));
        withdrawn = available < assets ? available : assets;
        if (withdrawn != 0) token.safeTransfer(receiver, withdrawn);

        uint256 totalAfter = _totalManagedAssets();
        uint256 reduction = totalBefore > totalAfter ? totalBefore - totalAfter : 0;
        loss = reduction > withdrawn ? reduction - withdrawn : 0;

        uint256 maximumLoss = assets * maxWithdrawalLossBps / BPS;
        if (loss > maximumLoss) revert WithdrawalLossExceeded(loss, maximumLoss);

        // Keep the strategy baseline aligned with the router's debt reduction. A venue may realize
        // lazy accrual while freeing funds, so the raw before/after valuation delta is not a stable
        // accounting input here.
        uint256 debtReduction = withdrawn + loss;
        uint256 baselineReduction =
            debtReduction < accountedAssets ? debtReduction : accountedAssets;
        accountedAssets -= baselineReduction;
        emit StrategyWithdrawal(receiver, assets, withdrawn, loss);
    }

    /// @inheritdoc ISeraphStrategy
    function harvest()
        external
        override
        onlyVault
        nonReentrant
        returns (StrategyReport memory report)
    {
        if (harvestPaused) revert HarvestIsPaused();

        uint256 baseline = accountedAssets;
        uint256 rewardAmount = _claimRewards();
        emit RewardsClaimed(rewardAmount);

        uint256 assetsAfterClaim = _totalManagedAssets();
        uint256 provisionalGain = assetsAfterClaim > baseline ? assetsAfterClaim - baseline : 0;

        uint256 debtPayment;
        if (realizeGains && provisionalGain != 0) {
            IERC20 token = IERC20(asset);
            uint256 idle = token.balanceOf(address(this));
            if (idle < provisionalGain) _freeFunds(provisionalGain - idle);

            uint256 available = token.balanceOf(address(this));
            debtPayment = available < provisionalGain ? available : provisionalGain;
            if (debtPayment != 0) token.safeTransfer(vault, debtPayment);
        }

        uint256 endingAssets = _totalManagedAssets();
        uint256 grossAssets = endingAssets + debtPayment;
        uint256 gain;
        uint256 loss;
        if (grossAssets >= baseline) {
            gain = grossAssets - baseline;
        } else {
            loss = baseline - grossAssets;
        }

        accountedAssets = endingAssets;
        lastReport = uint40(block.timestamp);
        report = StrategyReport({
            totalAssets: endingAssets,
            gain: gain,
            loss: loss,
            debtPayment: debtPayment,
            timestamp: uint40(block.timestamp)
        });

        emit StrategyReported(endingAssets, gain, loss, debtPayment);
    }

    /// @inheritdoc ISeraphStrategy
    function shutdown() external override onlyVault {
        if (status != StrategyStatus.Retiring) {
            status = StrategyStatus.Retiring;
            emit StrategyShutdown();
        }
    }

    /// @inheritdoc ISeraphStrategy
    function emergencyWithdraw(address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        if (receiver == address(0)) revert ZeroAddress();
        status = StrategyStatus.Retiring;

        _exitPosition();

        IERC20 token = IERC20(asset);
        withdrawn = token.balanceOf(address(this));
        if (withdrawn != 0) token.safeTransfer(receiver, withdrawn);

        uint256 remaining = _totalManagedAssets();
        // The router recognizes all pending PnL during an emergency exit and books `remaining` as
        // the new debt. Mirror that exact baseline so a later harvest can reconcile a partial exit.
        accountedAssets = remaining;

        emit StrategyShutdown();
        emit EmergencyWithdrawal(receiver, withdrawn, remaining);
    }

    /// @notice Pause new deployments while preserving withdrawals and reports.
    function pauseStrategy() external onlyGovernorOrGuardian {
        if (status != StrategyStatus.Active) revert InvalidStatus(status);
        status = StrategyStatus.Paused;
        emit StrategyPaused(msg.sender);
    }

    /// @notice Resume a governance-paused strategy.
    function resumeStrategy() external onlyGovernor {
        if (status != StrategyStatus.Paused) revert InvalidStatus(status);
        status = StrategyStatus.Active;
        emit StrategyResumed(msg.sender);
    }

    function setHarvestPaused(bool paused) external onlyGovernorOrGuardian {
        if (!paused && harvestPaused && msg.sender != governor) {
            revert UnauthorizedGovernor(msg.sender);
        }
        harvestPaused = paused;
        emit HarvestPauseSet(paused);
    }

    function setDepositLimit(uint256 newLimit) external onlyGovernor {
        uint256 previous = depositLimit;
        depositLimit = newLimit;
        emit DepositLimitSet(previous, newLimit);
    }

    function setSlippageLimits(uint16 depositSlippageBps, uint16 withdrawalLossBps)
        external
        onlyGovernor
    {
        if (depositSlippageBps > 1000 || withdrawalLossBps > 2000) {
            revert InvalidBps(depositSlippageBps > withdrawalLossBps
                    ? depositSlippageBps
                    : withdrawalLossBps);
        }
        maxDepositSlippageBps = depositSlippageBps;
        maxWithdrawalLossBps = withdrawalLossBps;
        emit SlippageLimitsSet(depositSlippageBps, withdrawalLossBps);
    }

    function setGainRealization(bool enabled) external onlyGovernor {
        realizeGains = enabled;
        emit GainRealizationSet(enabled);
    }

    /// @notice Recover a non-underlying token accidentally sent to the adapter.
    function rescueToken(address token, address receiver, uint256 amount) external onlyGovernor {
        if (token == asset) revert AssetRescueForbidden();
        if (token == address(0) || receiver == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(receiver, amount);
        emit TokenRescued(token, receiver, amount);
    }

    /// @dev Total asset value including idle tokens held directly by this contract.
    function _totalManagedAssets() internal view virtual returns (uint256);

    /// @dev Venue capacity, excluding the local `depositLimit`.
    function _maxDeployableAssets() internal view virtual returns (uint256);

    /// @dev Immediately liquid assets held at the external venue, excluding local idle assets.
    function _maxLiquidAssets() internal view virtual returns (uint256);

    /// @dev Deploy up to `assets` of local idle underlying into the external venue.
    function _deployFunds(uint256 assets) internal virtual;

    /// @dev Free approximately `assets` of underlying from the external venue.
    function _freeFunds(uint256 assets) internal virtual;

    /// @dev Claim venue rewards. Return value is informational and may use reward-token units.
    function _claimRewards() internal virtual returns (uint256 rewards);

    /// @dev Best-effort synchronous exit used by the emergency path.
    function _exitPosition() internal virtual;
}
