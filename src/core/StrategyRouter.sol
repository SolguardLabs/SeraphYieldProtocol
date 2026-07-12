// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ISeraphStrategy } from "../interfaces/ISeraphStrategy.sol";
import { IStrategyRouter } from "../interfaces/IStrategyRouter.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import {
    RebalanceAction,
    RebalanceInstruction,
    StrategyConfig,
    StrategyReport,
    StrategyState,
    StrategyStatus
} from "../types/SeraphTypes.sol";

/// @notice Registry, allocator, and debt ledger between a Seraph vault and its strategies.
contract StrategyRouter is IStrategyRouter, ProtocolAccess {
    using SafeTransferLib for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_STRATEGIES = 16;

    error OnlyVault(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error ReentrantRouterCall();
    error AllocationsArePaused();
    error ReportsArePaused();
    error StrategyAlreadyRegistered(address strategy);
    error StrategyNotRegistered(address strategy);
    error StrategyNotActive(address strategy);
    error StrategyHasNoTarget(address strategy);
    error InvalidStrategyAsset(address strategy, address expected, address actual);
    error InvalidStrategyVault(address strategy, address expected, address actual);
    error TooManyStrategies(uint256 maximum);
    error InvalidBps(uint256 bps);
    error InvalidWeightTotal(uint256 total);
    error ArrayLengthMismatch();
    error CapBelowDebt(uint256 cap, uint256 debt);
    error WeightMustBeZero(address strategy, uint256 weight);
    error DebtMustBeZero(address strategy, uint256 debt);
    error StrategyReturnMismatch(address strategy, uint256 reported, uint256 received);
    error StrategyReportMismatch(address strategy, uint256 expected, uint256 reported);
    error StrategyReportInFuture(address strategy, uint256 timestamp);
    error StrategyLossExceeded(address strategy, uint256 loss, uint256 maximum);
    error MinimumAssetsNotMet(uint256 received, uint256 minimum);
    error AllocationOutOfBounds(
        address strategy, uint256 debt, uint256 lowerBound, uint256 upperBound
    );
    error Uint128Overflow(uint256 value);

    event StrategyAdded(
        address indexed strategy, uint256 cap, uint16 maxDeviationBps, uint16 maxLossBps
    );
    event StrategyStatusSet(address indexed strategy, StrategyStatus status);
    event StrategyCapSet(address indexed strategy, uint256 previousCap, uint256 newCap);
    event StrategyRiskSet(address indexed strategy, uint16 maxDeviationBps, uint16 maxLossBps);
    event TargetWeightSet(address indexed strategy, uint16 previousWeight, uint16 newWeight);
    event CapitalDeployed(address indexed strategy, uint256 spent, uint256 accountedAssets);
    event CapitalWithdrawn(
        address indexed strategy, uint256 requested, uint256 received, uint256 loss
    );
    event StrategyHarvested(
        address indexed strategy, uint256 gain, uint256 loss, uint256 debtPayment, uint256 newDebt
    );
    event RouterPauseSet(bool allocationsPaused, bool reportsPaused);
    event StrategyEmergencyExited(
        address indexed strategy, uint256 recovered, uint256 remainingDebt, uint256 loss
    );

    address public immutable override asset;
    address public immutable override vault;
    uint256 public override totalDebt;
    uint16 public totalTargetWeight;
    bool public allocationsPaused;
    bool public reportsPaused;

    address[] private _strategies;
    mapping(address strategy => StrategyConfig config) private _configs;
    mapping(address strategy => StrategyState state) private _states;
    mapping(address strategy => uint16 maxLossBps) public strategyMaxLossBps;
    mapping(address strategy => bool registered) public isRegistered;

    uint256 private _entered;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert ReentrantRouterCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address asset_, address vault_, address initialGovernor, address initialGuardian)
        ProtocolAccess(initialGovernor, initialGuardian)
    {
        if (asset_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        asset = asset_;
        vault = vault_;
        _entered = 1;
    }

    function strategyCount() external view override returns (uint256) {
        return _strategies.length;
    }

    function strategyAt(uint256 index) external view override returns (address) {
        return _strategies[index];
    }

    function strategyConfig(address strategy)
        external
        view
        override
        returns (StrategyConfig memory)
    {
        return _configs[strategy];
    }

    function strategyState(address strategy) external view override returns (StrategyState memory) {
        return _states[strategy];
    }

    /// @notice Add a strategy with zero target weight; weights are activated atomically later.
    function addStrategy(
        address strategy,
        uint128 depositCap,
        uint16 maxDeviationBps,
        uint16 maxLossBps
    ) external onlyGovernor {
        if (strategy == address(0)) revert ZeroAddress();
        if (isRegistered[strategy]) revert StrategyAlreadyRegistered(strategy);
        if (_strategies.length >= MAX_STRATEGIES) revert TooManyStrategies(MAX_STRATEGIES);
        if (maxDeviationBps > BPS || maxLossBps > 2000) {
            revert InvalidBps(maxDeviationBps > maxLossBps ? maxDeviationBps : maxLossBps);
        }

        address strategyAsset = ISeraphStrategy(strategy).asset();
        if (strategyAsset != asset) {
            revert InvalidStrategyAsset(strategy, asset, strategyAsset);
        }
        address strategyVault = ISeraphStrategy(strategy).vault();
        if (strategyVault != address(this)) {
            revert InvalidStrategyVault(strategy, address(this), strategyVault);
        }

        _configs[strategy] = StrategyConfig({
            strategy: strategy,
            depositCap: depositCap,
            activatedAt: uint40(block.timestamp),
            targetBps: 0,
            maxDeviationBps: maxDeviationBps,
            status: StrategyStatus.Active
        });
        strategyMaxLossBps[strategy] = maxLossBps;
        isRegistered[strategy] = true;
        _strategies.push(strategy);
        emit StrategyAdded(strategy, depositCap, maxDeviationBps, maxLossBps);
    }

    /// @notice Replace all active target weights; the resulting sum must be exactly 10,000 bps.
    function setTargetWeights(address[] calldata strategies, uint16[] calldata weights)
        external
        onlyGovernor
    {
        if (strategies.length != weights.length) revert ArrayLengthMismatch();

        for (uint256 i; i < strategies.length; ++i) {
            address strategy = strategies[i];
            _requireRegistered(strategy);
            StrategyConfig storage config = _configs[strategy];
            if (config.status != StrategyStatus.Active && weights[i] != 0) {
                revert StrategyNotActive(strategy);
            }
            uint16 previous = config.targetBps;
            config.targetBps = weights[i];
            emit TargetWeightSet(strategy, previous, weights[i]);
        }

        uint256 sum;
        for (uint256 i; i < _strategies.length; ++i) {
            sum += _configs[_strategies[i]].targetBps;
        }
        if (sum != BPS) revert InvalidWeightTotal(sum);
        // The equality check above proves that `sum` is exactly 10,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        totalTargetWeight = uint16(sum);
    }

    function setStrategyCap(address strategy, uint128 newCap) external onlyGovernor {
        _requireRegistered(strategy);
        uint256 debt = _states[strategy].debt;
        if (newCap != 0 && newCap < debt) revert CapBelowDebt(newCap, debt);
        uint256 previous = _configs[strategy].depositCap;
        _configs[strategy].depositCap = newCap;
        emit StrategyCapSet(strategy, previous, newCap);
    }

    function setStrategyRisk(address strategy, uint16 deviationBps, uint16 maxLossBps)
        external
        onlyGovernor
    {
        _requireRegistered(strategy);
        if (deviationBps > BPS || maxLossBps > 2000) {
            revert InvalidBps(deviationBps > maxLossBps ? deviationBps : maxLossBps);
        }
        _configs[strategy].maxDeviationBps = deviationBps;
        strategyMaxLossBps[strategy] = maxLossBps;
        emit StrategyRiskSet(strategy, deviationBps, maxLossBps);
    }

    /// @notice Stop allocating to a zero-weight strategy and ask it to begin an orderly unwind.
    function retireStrategy(address strategy) external onlyGovernor {
        _requireRegistered(strategy);
        StrategyConfig storage config = _configs[strategy];
        if (config.targetBps != 0) revert WeightMustBeZero(strategy, config.targetBps);
        config.status = StrategyStatus.Retiring;
        ISeraphStrategy(strategy).shutdown();
        emit StrategyStatusSet(strategy, StrategyStatus.Retiring);
    }

    /// @notice Mark a fully unwound strategy inactive. Historical state remains queryable.
    function deactivateStrategy(address strategy) external onlyGovernor {
        _requireRegistered(strategy);
        uint256 debt = _states[strategy].debt;
        if (debt != 0) revert DebtMustBeZero(strategy, debt);
        StrategyConfig storage config = _configs[strategy];
        if (config.targetBps != 0) revert WeightMustBeZero(strategy, config.targetBps);
        config.status = StrategyStatus.Inactive;
        emit StrategyStatusSet(strategy, StrategyStatus.Inactive);
    }

    /// @inheritdoc IStrategyRouter
    function deploy(uint256 assets)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 deployed)
    {
        if (allocationsPaused) revert AllocationsArePaused();
        if (assets == 0) revert ZeroAmount();
        if (totalTargetWeight != BPS) revert InvalidWeightTotal(totalTargetWeight);

        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(vault, address(this), assets);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;

        (deployed,) = _allocate(received);

        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 refundable = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (refundable != 0) token.safeTransfer(vault, refundable);
    }

    /// @inheritdoc IStrategyRouter
    function pullToVault(uint256 assets)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 received, uint256 loss)
    {
        if (assets == 0) return (0, 0);

        for (uint256 cursor = _strategies.length; cursor != 0 && received < assets;) {
            unchecked {
                --cursor;
            }
            address strategy = _strategies[cursor];
            if (_states[strategy].debt == 0) continue;

            uint256 request = assets - received;
            (uint256 amountOut, uint256 strategyLoss) = _withdrawFrom(strategy, request);
            received += amountOut;
            loss += strategyLoss;
        }

        if (received != 0) IERC20(asset).safeTransfer(vault, received);
    }

    /// @inheritdoc IStrategyRouter
    function harvest(address[] calldata strategies)
        external
        override
        onlyVault
        nonReentrant
        returns (HarvestSummary memory summary)
    {
        if (reportsPaused) revert ReportsArePaused();
        IERC20 token = IERC20(asset);
        uint256 initialBalance = token.balanceOf(address(this));

        for (uint256 i; i < strategies.length; ++i) {
            address strategy = strategies[i];
            _requireRegistered(strategy);
            StrategyState storage state = _states[strategy];
            uint256 oldDebt = state.debt;
            uint256 balanceBefore = token.balanceOf(address(this));
            StrategyReport memory report = ISeraphStrategy(strategy).harvest();
            uint256 payment = token.balanceOf(address(this)) - balanceBefore;

            if (payment != report.debtPayment) {
                revert StrategyReturnMismatch(strategy, report.debtPayment, payment);
            }
            // Timestamp is metadata sanity checking, not a source of economic randomness.
            // forge-lint: disable-next-line(block-timestamp)
            if (report.timestamp > block.timestamp) {
                revert StrategyReportInFuture(strategy, report.timestamp);
            }
            if (oldDebt + report.gain < report.loss + report.debtPayment) {
                revert StrategyReportMismatch(strategy, 0, report.totalAssets);
            }
            uint256 expected = oldDebt + report.gain - report.loss - report.debtPayment;
            if (expected != report.totalAssets) {
                revert StrategyReportMismatch(strategy, expected, report.totalAssets);
            }

            totalDebt = totalDebt - oldDebt + report.totalAssets;
            state.debt = _toUint128(report.totalAssets);
            state.reportedAssets = _toUint128(report.totalAssets);
            state.cumulativeGain = _toUint128(uint256(state.cumulativeGain) + report.gain);
            state.cumulativeLoss = _toUint128(uint256(state.cumulativeLoss) + report.loss);
            state.lastReport = report.timestamp;
            unchecked {
                ++state.reportNonce;
            }

            summary.gain += report.gain;
            summary.loss += report.loss;
            summary.debtPayment += payment;
            ++summary.strategiesReported;
            emit StrategyHarvested(strategy, report.gain, report.loss, payment, report.totalAssets);
        }

        uint256 realized = token.balanceOf(address(this)) - initialBalance;
        if (realized != summary.debtPayment) {
            revert StrategyReturnMismatch(address(this), summary.debtPayment, realized);
        }
        if (realized != 0) token.safeTransfer(vault, realized);
    }

    /// @inheritdoc IStrategyRouter
    function rebalance(RebalanceInstruction[] calldata instructions)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 deployed, uint256 withdrawn, uint256 loss)
    {
        IERC20 token = IERC20(asset);
        uint256 initialBalance = token.balanceOf(address(this));

        for (uint256 i; i < instructions.length; ++i) {
            RebalanceInstruction calldata instruction = instructions[i];
            _requireRegistered(instruction.strategy);

            if (instruction.action == RebalanceAction.Withdraw) {
                (uint256 amountOut, uint256 strategyLoss) =
                    _withdrawFrom(instruction.strategy, instruction.assets);
                if (amountOut < instruction.minAssetsOut) {
                    revert MinimumAssetsNotMet(amountOut, instruction.minAssetsOut);
                }
                withdrawn += amountOut;
                loss += strategyLoss;
            } else {
                uint256 available = token.balanceOf(address(this));
                if (available < instruction.assets) {
                    token.safeTransferFrom(vault, address(this), instruction.assets - available);
                    available = token.balanceOf(address(this));
                }
                uint256 amount = instruction.assets < available ? instruction.assets : available;
                uint256 amountDeployed = _depositInto(instruction.strategy, amount);
                if (amountDeployed < instruction.minAssetsOut) {
                    revert MinimumAssetsNotMet(amountDeployed, instruction.minAssetsOut);
                }
                deployed += amountDeployed;
            }
        }

        if (deployed != 0) _validateAllocationBounds();

        uint256 endingBalance = token.balanceOf(address(this));
        uint256 excess = endingBalance > initialBalance ? endingBalance - initialBalance : 0;
        if (excess != 0) token.safeTransfer(vault, excess);
    }

    function setRouterPause(bool pauseAllocations, bool pauseReports)
        external
        onlyGovernorOrGuardian
    {
        bool unpausing =
            (!pauseAllocations && allocationsPaused) || (!pauseReports && reportsPaused);
        if (unpausing && msg.sender != governor) revert UnauthorizedGovernor(msg.sender);
        allocationsPaused = pauseAllocations;
        reportsPaused = pauseReports;
        emit RouterPauseSet(pauseAllocations, pauseReports);
    }

    /// @notice Best-effort venue exit. Recovered assets are forwarded directly to the vault.
    function emergencyExitStrategy(address strategy)
        external
        onlyGovernorOrGuardian
        nonReentrant
        returns (uint256 recovered, uint256 loss)
    {
        _requireRegistered(strategy);
        StrategyConfig storage config = _configs[strategy];
        uint16 previousWeight = config.targetBps;
        config.targetBps = 0;
        totalTargetWeight -= previousWeight;
        config.status = StrategyStatus.Retiring;

        ISeraphStrategy adapter = ISeraphStrategy(strategy);
        adapter.shutdown();
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        adapter.emergencyWithdraw(address(this));
        recovered = token.balanceOf(address(this)) - balanceBefore;

        StrategyState storage state = _states[strategy];
        uint256 oldDebt = state.debt;
        uint256 remaining = adapter.totalAssets();
        uint256 covered = recovered + remaining;
        loss = oldDebt > covered ? oldDebt - covered : 0;
        uint256 gain = covered > oldDebt ? covered - oldDebt : 0;
        totalDebt = totalDebt - oldDebt + remaining;
        state.debt = _toUint128(remaining);
        state.reportedAssets = _toUint128(remaining);
        state.cumulativeLoss = _toUint128(uint256(state.cumulativeLoss) + loss);
        state.cumulativeGain = _toUint128(uint256(state.cumulativeGain) + gain);
        state.lastReport = uint40(block.timestamp);

        if (recovered != 0) token.safeTransfer(vault, recovered);
        emit TargetWeightSet(strategy, previousWeight, 0);
        emit StrategyStatusSet(strategy, StrategyStatus.Retiring);
        emit StrategyEmergencyExited(strategy, recovered, remaining, loss);
    }

    function _allocate(uint256 assets) private returns (uint256 deployed, uint256 spent) {
        if (assets == 0) return (0, 0);
        uint256 projectedPortfolio = totalDebt + assets;

        for (uint256 i; i < _strategies.length && spent < assets; ++i) {
            address strategy = _strategies[i];
            StrategyConfig storage config = _configs[strategy];
            if (config.status != StrategyStatus.Active || config.targetBps == 0) continue;

            uint256 targetDebt = projectedPortfolio * config.targetBps / BPS;
            uint256 currentDebt = _states[strategy].debt;
            if (currentDebt >= targetDebt) continue;

            uint256 request = targetDebt - currentDebt;
            uint256 remaining = assets - spent;
            if (request > remaining) request = remaining;
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            uint256 accounted = _depositInto(strategy, request);
            uint256 consumed = balanceBefore - IERC20(asset).balanceOf(address(this));
            deployed += accounted;
            spent += consumed;
        }
    }

    function _depositInto(address strategy, uint256 assets) private returns (uint256 deployed) {
        if (assets == 0) return 0;
        StrategyConfig storage config = _configs[strategy];
        if (config.status != StrategyStatus.Active) revert StrategyNotActive(strategy);
        if (config.targetBps == 0) revert StrategyHasNoTarget(strategy);
        if (totalTargetWeight != BPS) revert InvalidWeightTotal(totalTargetWeight);
        if (allocationsPaused) revert AllocationsArePaused();

        IERC20 token = IERC20(asset);
        StrategyState storage state = _states[strategy];
        uint256 debt = state.debt;
        uint256 capacity = _depositCapacity(strategy, debt);
        if (assets > capacity) assets = capacity;
        if (assets == 0) return 0;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.forceApprove(strategy, assets);
        deployed = ISeraphStrategy(strategy).deposit(assets);
        token.forceApprove(strategy, 0);
        uint256 spent = balanceBefore - token.balanceOf(address(this));
        if (spent != assets) revert StrategyReturnMismatch(strategy, assets, spent);
        if (deployed > spent) revert StrategyReturnMismatch(strategy, deployed, spent);

        state.debt = _toUint128(debt + deployed);
        state.reportedAssets = state.debt;
        totalDebt += deployed;
        emit CapitalDeployed(strategy, spent, deployed);
    }

    function _depositCapacity(address strategy, uint256 debt)
        private
        view
        returns (uint256 capacity)
    {
        StrategyConfig storage config = _configs[strategy];
        if (config.depositCap != 0 && debt >= config.depositCap) return 0;
        capacity = config.depositCap == 0 ? type(uint256).max : config.depositCap - debt;

        uint256 portfolio = totalDebt + IERC20(asset).balanceOf(address(this));
        uint256 target = MathLib.bpsMulDown(portfolio, config.targetBps);
        uint256 deviation = MathLib.bpsMulDown(portfolio, config.maxDeviationBps);
        uint256 upper =
            target > type(uint256).max - deviation ? type(uint256).max : target + deviation;
        if (debt >= upper) return 0;

        uint256 allocationCapacity = upper - debt;
        if (capacity > allocationCapacity) capacity = allocationCapacity;
        uint256 adapterCapacity = ISeraphStrategy(strategy).maxDeposit();
        if (capacity > adapterCapacity) capacity = adapterCapacity;
    }

    function _withdrawFrom(address strategy, uint256 assets)
        private
        returns (uint256 received, uint256 loss)
    {
        if (assets == 0) return (0, 0);
        StrategyState storage state = _states[strategy];
        uint256 oldDebt = state.debt;
        if (oldDebt == 0) return (0, 0);

        uint256 liquid = ISeraphStrategy(strategy).maxWithdraw();
        uint256 request = assets < oldDebt ? assets : oldDebt;
        if (request > liquid) request = liquid;
        if (request == 0) return (0, 0);

        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        (uint256 reported, uint256 reportedLoss) =
            ISeraphStrategy(strategy).withdraw(request, address(this));
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received != reported) revert StrategyReturnMismatch(strategy, reported, received);

        uint256 maximumLoss = request * strategyMaxLossBps[strategy] / BPS;
        if (reportedLoss > maximumLoss) {
            revert StrategyLossExceeded(strategy, reportedLoss, maximumLoss);
        }
        loss = reportedLoss;
        uint256 reduction = received + loss;
        if (reduction > oldDebt) reduction = oldDebt;

        state.debt = _toUint128(oldDebt - reduction);
        state.reportedAssets = state.debt;
        state.cumulativeLoss = _toUint128(uint256(state.cumulativeLoss) + loss);
        totalDebt -= reduction;
        emit CapitalWithdrawn(strategy, request, received, loss);
    }

    function _requireRegistered(address strategy) private view {
        if (!isRegistered[strategy]) revert StrategyNotRegistered(strategy);
    }

    function _validateAllocationBounds() private view {
        uint256 portfolio = totalDebt;
        if (portfolio == 0) return;

        for (uint256 i; i < _strategies.length; ++i) {
            address strategy = _strategies[i];
            StrategyConfig storage config = _configs[strategy];
            if (config.status != StrategyStatus.Active || config.targetBps == 0) continue;

            uint256 target = MathLib.bpsMulDown(portfolio, config.targetBps);
            uint256 deviation = MathLib.bpsMulDown(portfolio, config.maxDeviationBps);
            uint256 lower = MathLib.saturatingSub(target, deviation);
            uint256 upper =
                target > type(uint256).max - deviation ? type(uint256).max : target + deviation;
            uint256 debt = _states[strategy].debt;

            // One wei of tolerance avoids rejecting otherwise exact integer-weight allocations.
            bool below = debt < lower && lower - debt > 1;
            bool above = debt > upper && debt - upper > 1;
            if (below || above) {
                revert AllocationOutOfBounds(strategy, debt, lower, upper);
            }
        }
    }

    function _toUint128(uint256 value) private pure returns (uint128 result) {
        if (value > type(uint128).max) revert Uint128Overflow(value);
        // The explicit bound check above proves that truncation is impossible.
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint128(value);
    }
}
