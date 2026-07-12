// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20, IERC20Metadata } from "../interfaces/IERC20.sol";
import { IFeeController } from "../interfaces/IFeeController.sol";
import { IRewardDistributor } from "../interfaces/IRewardDistributor.sol";
import { IRiskController } from "../interfaces/IRiskController.sol";
import { ISeraphShare } from "../interfaces/ISeraphShare.sol";
import { IStrategyRouter } from "../interfaces/IStrategyRouter.sol";
import { IWithdrawalQueue } from "../interfaces/IWithdrawalQueue.sol";
import { MathLib } from "../libraries/MathLib.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import { ProtocolAccess } from "../security/ProtocolAccess.sol";
import { ReentrancyGuard } from "../security/ReentrancyGuard.sol";
import {
    RebalanceInstruction,
    SeraphConstants,
    VaultSnapshot,
    WithdrawalRequest
} from "../types/SeraphTypes.sol";

/// @title SeraphVault
/// @notice Single-asset yield vault with strategy allocation and delayed withdrawals.
contract SeraphVault is ProtocolAccess, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    struct HarvestSettlement {
        uint256 economicGain;
        uint256 performanceFeeAssets;
        uint256 managementFeeAssets;
        uint256 rewardAssets;
        uint256 totalFees;
        uint256 compoundAssets;
    }

    error InvalidAsset();
    error InvalidModule(address module);
    error InvalidReceiver();
    error InvalidAmount();
    error InvalidRewardAllocation();
    error AlreadyInitialized();
    error NotInitialized();
    error ProtocolPaused();
    error DepositsPaused();
    error InsufficientShares(uint256 actual, uint256 minimum);
    error ExcessiveAssets(uint256 actual, uint256 maximum);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error UnsupportedToken(address token);

    event ModulesInitialized(
        address indexed share,
        address indexed rewardDistributor,
        address indexed withdrawalQueue,
        address strategyRouter,
        address riskController,
        address feeController
    );
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assetsAtRequest,
        uint256 minimumAssets
    );
    event WithdrawalCancelled(uint256 indexed requestId, address indexed owner, uint256 shares);
    event WithdrawalExecuted(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assets,
        uint256 feeAssets,
        address executor
    );
    event StrategyCapitalDeployed(uint256 requestedAssets, uint256 deployedAssets);
    event StrategyCapitalPulled(uint256 requestedAssets, uint256 receivedAssets, uint256 loss);
    event HarvestProcessed(
        uint256 grossGain,
        uint256 loss,
        uint256 performanceFee,
        uint256 managementFee,
        uint256 rewardAssets,
        uint256 compoundAssets,
        uint256 strategiesReported
    );
    event RewardAllocationUpdated(uint256 previousBps, uint256 newBps);
    event ProtocolPauseUpdated(bool paused);
    event DepositPauseUpdated(bool paused);
    event TokenRecovered(address indexed token, address indexed receiver, uint256 amount);

    IERC20 public immutable underlying;
    uint8 public immutable assetDecimals;
    uint256 public immutable virtualAssets;
    uint256 public immutable virtualShares;

    ISeraphShare public share;
    IRewardDistributor public rewards;
    IWithdrawalQueue public withdrawalQueue;
    IStrategyRouter public strategyRouter;
    IRiskController public riskController;
    IFeeController public feeController;

    uint256 public rewardAllocationBps;
    uint256 public cumulativeDeposits;
    uint256 public cumulativeWithdrawals;
    uint256 public cumulativeStrategyGain;
    uint256 public cumulativeStrategyLoss;
    uint40 public lastHarvest;
    bool public initialized;
    bool public protocolPaused;
    bool public depositPaused;

    modifier whenOperational() {
        if (protocolPaused) revert ProtocolPaused();
        _;
    }

    modifier whenDepositsEnabled() {
        if (protocolPaused) revert ProtocolPaused();
        if (depositPaused) revert DepositsPaused();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    constructor(
        address asset_,
        address initialGovernor,
        address initialGuardian,
        uint256 initialRewardAllocationBps
    ) ProtocolAccess(initialGovernor, initialGuardian) {
        if (asset_ == address(0)) revert InvalidAsset();
        if (initialRewardAllocationBps > SeraphConstants.BPS) {
            revert InvalidRewardAllocation();
        }

        uint8 decimals_;
        try IERC20Metadata(asset_).decimals() returns (uint8 value) {
            decimals_ = value;
        } catch {
            revert InvalidAsset();
        }
        if (decimals_ > 18) revert InvalidAsset();

        underlying = IERC20(asset_);
        assetDecimals = decimals_;
        virtualAssets = 10 ** decimals_;
        virtualShares = 10 ** decimals_;
        rewardAllocationBps = initialRewardAllocationBps;
    }

    /// @notice Connects the vault's independently deployed accounting modules.
    function initialize(
        address share_,
        address rewards_,
        address withdrawalQueue_,
        address strategyRouter_,
        address riskController_,
        address feeController_
    ) external onlyGovernor {
        if (initialized) revert AlreadyInitialized();
        if (
            share_ == address(0) || rewards_ == address(0) || withdrawalQueue_ == address(0)
                || strategyRouter_ == address(0) || riskController_ == address(0)
                || feeController_ == address(0)
        ) revert InvalidModule(address(0));

        ISeraphShare shareModule = ISeraphShare(share_);
        IWithdrawalQueue queueModule = IWithdrawalQueue(withdrawalQueue_);
        IStrategyRouter routerModule = IStrategyRouter(strategyRouter_);

        if (shareModule.vault() != address(this)) revert InvalidModule(share_);
        if (queueModule.vault() != address(this)) revert InvalidModule(withdrawalQueue_);
        if (routerModule.vault() != address(this) || routerModule.asset() != address(underlying)) {
            revert InvalidModule(strategyRouter_);
        }

        share = shareModule;
        rewards = IRewardDistributor(rewards_);
        withdrawalQueue = queueModule;
        strategyRouter = routerModule;
        riskController = IRiskController(riskController_);
        feeController = IFeeController(feeController_);

        shareModule.setQueue(withdrawalQueue_);
        shareModule.setTransferHook(rewards_);
        underlying.forceApprove(strategyRouter_, type(uint256).max);

        initialized = true;
        emit ModulesInitialized(
            share_, rewards_, withdrawalQueue_, strategyRouter_, riskController_, feeController_
        );
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalSupply() public view returns (uint256) {
        return initialized ? share.totalSupply() : 0;
    }

    function totalAssets() public view returns (uint256) {
        uint256 idle = underlying.balanceOf(address(this));
        return initialized ? idle + strategyRouter.totalDebt() : idle;
    }

    function idleAssets() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function strategyAssets() public view returns (uint256) {
        return initialized ? strategyRouter.totalDebt() : 0;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return
            MathLib.mulDivDown(assets, totalSupply() + virtualShares, totalAssets() + virtualAssets);
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return
            MathLib.mulDivDown(
                shares_, totalAssets() + virtualAssets, totalSupply() + virtualShares
            );
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares_) public view returns (uint256) {
        return
            MathLib.mulDivUp(shares_, totalAssets() + virtualAssets, totalSupply() + virtualShares);
    }

    function previewRedeem(uint256 shares_) public view returns (uint256) {
        return convertToAssets(shares_);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return
            MathLib.mulDivUp(assets, totalSupply() + virtualShares, totalAssets() + virtualAssets);
    }

    function previewRequest(uint256 shares_)
        public
        view
        returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets)
    {
        grossAssets = previewRedeem(shares_);
        feeAssets = initialized ? feeController.withdrawalFee(grossAssets) : 0;
        netAssets = grossAssets - feeAssets;
    }

    function maxDeposit(address) external view returns (uint256) {
        if (!initialized || protocolPaused || depositPaused) return 0;
        uint256 cap = riskController.depositCap();
        if (cap == 0) return type(uint256).max;
        return MathLib.saturatingSub(cap, totalAssets());
    }

    function maxMint(address receiver) external view returns (uint256) {
        if (!initialized || protocolPaused || depositPaused) return 0;
        uint256 cap = riskController.depositCap();
        if (cap == 0) return type(uint256).max;
        uint256 remainingAssets = MathLib.saturatingSub(cap, totalAssets());
        receiver;
        return convertToShares(remainingAssets);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        if (!initialized || protocolPaused) return 0;
        return share.activeBalanceOf(owner);
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 sharesMinted) {
        return deposit(assets, receiver, 0);
    }

    function deposit(uint256 assets, address receiver, uint256 minimumShares)
        public
        onlyInitialized
        whenDepositsEnabled
        nonReentrant
        returns (uint256 sharesMinted)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (assets == 0) revert InvalidAmount();

        riskController.validateDeposit(totalAssets(), assets);
        sharesMinted = previewDeposit(assets);
        if (sharesMinted == 0 || sharesMinted < minimumShares) {
            revert InsufficientShares(sharesMinted, minimumShares);
        }

        underlying.safeTransferFrom(msg.sender, address(this), assets);
        share.mint(receiver, sharesMinted);
        cumulativeDeposits += assets;

        emit Deposit(msg.sender, receiver, assets, sharesMinted);
    }

    function mint(uint256 shares_, address receiver, uint256 maximumAssets)
        external
        onlyInitialized
        whenDepositsEnabled
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (shares_ == 0) revert InvalidAmount();

        assets = previewMint(shares_);
        if (assets > maximumAssets) revert ExcessiveAssets(assets, maximumAssets);
        riskController.validateDeposit(totalAssets(), assets);

        underlying.safeTransferFrom(msg.sender, address(this), assets);
        share.mint(receiver, shares_);
        cumulativeDeposits += assets;

        emit Deposit(msg.sender, receiver, assets, shares_);
    }

    function requestWithdrawal(uint256 shares_, address receiver, uint256 minimumAssets)
        external
        onlyInitialized
        whenOperational
        nonReentrant
        returns (uint256 requestId)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (shares_ == 0) revert InvalidAmount();

        riskController.validateRequest(
            share.totalSupply(),
            share.totalLocked(),
            share.balanceOf(msg.sender),
            share.lockedBalanceOf(msg.sender),
            shares_
        );

        rewards.checkpoint(msg.sender);
        share.lock(msg.sender, shares_);

        (,, uint256 assetsAtRequest) = previewRequest(shares_);
        requestId = withdrawalQueue.enqueue(
            msg.sender, receiver, shares_, assetsAtRequest, minimumAssets
        );

        emit WithdrawalRequested(
            requestId, msg.sender, receiver, shares_, assetsAtRequest, minimumAssets
        );
    }

    function cancelWithdrawal(uint256 requestId)
        external
        onlyInitialized
        nonReentrant
        returns (uint256 sharesUnlocked)
    {
        WithdrawalRequest memory requestData = withdrawalQueue.cancel(requestId, msg.sender);
        sharesUnlocked = requestData.shares;
        share.unlock(requestData.owner, sharesUnlocked);
        rewards.checkpoint(requestData.owner);

        emit WithdrawalCancelled(requestId, requestData.owner, sharesUnlocked);
    }

    function executeWithdrawal(uint256 requestId)
        external
        onlyInitialized
        whenOperational
        nonReentrant
        returns (uint256 assets)
    {
        return _executeWithdrawal(requestId, msg.sender);
    }

    function executeWithdrawals(uint256[] calldata requestIds)
        external
        onlyInitialized
        whenOperational
        nonReentrant
        returns (uint256 totalPaid)
    {
        for (uint256 i; i < requestIds.length; ++i) {
            totalPaid += _executeWithdrawal(requestIds[i], msg.sender);
        }
    }

    function claimRewards(address receiver)
        external
        onlyInitialized
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        return rewards.claimFor(msg.sender, receiver);
    }

    function deployIdle(uint256 maximumAssets)
        external
        onlyInitialized
        onlyGovernorOrKeeper
        whenOperational
        nonReentrant
        returns (uint256 deployed)
    {
        uint256 idle = idleAssets();
        uint256 requiredIdle = riskController.targetIdle(totalAssets());
        uint256 available = MathLib.saturatingSub(idle, requiredIdle);
        uint256 requested = MathLib.min(maximumAssets, available);
        if (requested == 0) return 0;

        deployed = strategyRouter.deploy(requested);
        emit StrategyCapitalDeployed(requested, deployed);
    }

    function pullFromStrategies(uint256 assets)
        external
        onlyInitialized
        onlyGovernorOrKeeper
        nonReentrant
        returns (uint256 received, uint256 loss)
    {
        (received, loss) = strategyRouter.pullToVault(assets);
        emit StrategyCapitalPulled(assets, received, loss);
    }

    function rebalance(RebalanceInstruction[] calldata instructions)
        external
        onlyInitialized
        onlyGovernorOrKeeper
        whenOperational
        nonReentrant
        returns (uint256 deployed, uint256 withdrawn, uint256 loss)
    {
        return strategyRouter.rebalance(instructions);
    }

    function harvest(address[] calldata strategies)
        external
        onlyInitialized
        onlyGovernorOrKeeper
        nonReentrant
        returns (IStrategyRouter.HarvestSummary memory summary)
    {
        uint256 debtBefore = strategyRouter.totalDebt();
        summary = strategyRouter.harvest(strategies);
        riskController.validateReport(debtBefore, summary.loss);

        cumulativeStrategyGain += summary.gain;
        cumulativeStrategyLoss += summary.loss;
        lastHarvest = MathLib.toUint40(block.timestamp);
        _settleHarvest(summary);
    }

    function snapshot() external view returns (VaultSnapshot memory state) {
        state.idleAssets = idleAssets();
        state.strategyAssets = strategyAssets();
        state.grossAssets = state.idleAssets + state.strategyAssets;
        if (initialized) {
            state.lockedSupply = share.totalLocked();
            state.activeSupply = share.activeSupply();
            state.reservedAssets = convertToAssets(state.lockedSupply);
        }
        state.timestamp = MathLib.toUint40(block.timestamp);
    }

    function setRewardAllocationBps(uint256 newRewardAllocationBps) external onlyGovernor {
        if (newRewardAllocationBps > SeraphConstants.BPS) revert InvalidRewardAllocation();
        uint256 previous = rewardAllocationBps;
        rewardAllocationBps = newRewardAllocationBps;
        emit RewardAllocationUpdated(previous, newRewardAllocationBps);
    }

    function setProtocolPaused(bool paused) external onlyGovernorOrGuardian {
        if (!paused && msg.sender != governor) revert ProtocolPaused();
        protocolPaused = paused;
        emit ProtocolPauseUpdated(paused);
    }

    function setDepositPaused(bool paused) external onlyGovernorOrGuardian {
        if (!paused && msg.sender != governor) revert DepositsPaused();
        depositPaused = paused;
        emit DepositPauseUpdated(paused);
    }

    function recoverToken(address token, address receiver, uint256 amount) external onlyGovernor {
        if (token == address(underlying)) revert UnsupportedToken(token);
        if (receiver == address(0)) revert InvalidReceiver();
        IERC20(token).safeTransfer(receiver, amount);
        emit TokenRecovered(token, receiver, amount);
    }

    function _executeWithdrawal(uint256 requestId, address executor)
        internal
        returns (uint256 netAssets)
    {
        WithdrawalRequest memory requestData = withdrawalQueue.request(requestId);
        rewards.checkpoint(requestData.owner);

        uint256 grossEstimate = previewRedeem(requestData.shares);
        _ensureLiquidity(grossEstimate);

        uint256 grossAssets = previewRedeem(requestData.shares);
        if (idleAssets() < grossAssets) _ensureLiquidity(grossAssets);
        uint256 feeAssets = feeController.withdrawalFee(grossAssets);
        netAssets = grossAssets - feeAssets;

        requestData = withdrawalQueue.consume(requestId, executor, netAssets);
        share.burnLocked(requestData.owner, requestData.shares);

        if (feeAssets != 0) underlying.safeTransfer(feeController.recipient(), feeAssets);
        underlying.safeTransfer(requestData.receiver, netAssets);
        cumulativeWithdrawals += grossAssets;

        emit WithdrawalExecuted(
            requestId,
            requestData.owner,
            requestData.receiver,
            requestData.shares,
            netAssets,
            feeAssets,
            executor
        );
    }

    function _settleHarvest(IStrategyRouter.HarvestSummary memory summary) internal {
        HarvestSettlement memory settlement;
        uint256 realizedGain = MathLib.min(summary.gain, summary.debtPayment);
        settlement.economicGain = MathLib.saturatingSub(realizedGain, summary.loss);
        settlement.performanceFeeAssets = feeController.performanceFee(settlement.economicGain);
        settlement.managementFeeAssets = feeController.checkpointManagementFee(totalAssets());
        uint256 gainAfterPerformanceFee = settlement.economicGain - settlement.performanceFeeAssets;
        settlement.rewardAssets = MathLib.bpsMulDown(gainAfterPerformanceFee, rewardAllocationBps);
        settlement.totalFees = settlement.performanceFeeAssets + settlement.managementFeeAssets;

        _ensureLiquidity(settlement.totalFees + settlement.rewardAssets);
        if (settlement.totalFees != 0) {
            underlying.safeTransfer(feeController.recipient(), settlement.totalFees);
        }
        if (settlement.rewardAssets != 0) {
            underlying.safeTransfer(address(rewards), settlement.rewardAssets);
            rewards.notifyReward(settlement.rewardAssets);
        }

        settlement.compoundAssets = realizedGain
            - MathLib.min(realizedGain, settlement.performanceFeeAssets + settlement.rewardAssets);
        emit HarvestProcessed(
            summary.gain,
            summary.loss,
            settlement.performanceFeeAssets,
            settlement.managementFeeAssets,
            settlement.rewardAssets,
            settlement.compoundAssets,
            summary.strategiesReported
        );
    }

    function _ensureLiquidity(uint256 requiredAssets) internal {
        uint256 idle = idleAssets();
        if (idle >= requiredAssets) return;

        uint256 shortfall = requiredAssets - idle;
        (uint256 received, uint256 loss) = strategyRouter.pullToVault(shortfall);
        emit StrategyCapitalPulled(shortfall, received, loss);

        uint256 available = idleAssets();
        if (available < requiredAssets && loss == 0) {
            revert InsufficientLiquidity(available, requiredAssets);
        }
    }
}
