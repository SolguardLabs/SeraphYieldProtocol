// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { FeeController } from "../src/core/FeeController.sol";
import { RewardDistributor } from "../src/core/RewardDistributor.sol";
import { RiskController } from "../src/core/RiskController.sol";
import { SeraphVault } from "../src/core/SeraphVault.sol";
import { StrategyRouter } from "../src/core/StrategyRouter.sol";
import { WithdrawalQueue } from "../src/core/WithdrawalQueue.sol";
import { IStrategyRouter } from "../src/interfaces/IStrategyRouter.sol";
import { SeraphShare } from "../src/token/SeraphShare.sol";
import { FeeConfig } from "../src/types/SeraphTypes.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockStrategy } from "./mocks/MockStrategy.sol";

abstract contract SeraphTestBase is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant WITHDRAWAL_DELAY = 1 days;
    uint256 internal constant CLAIM_WINDOW = 2 days;
    uint128 internal constant STRATEGY_CAP = 10_000_000e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant GUARDIAN = address(0x600D);
    address internal constant KEEPER = address(0xBEEF);
    address internal constant TREASURY = address(0x7EA5);

    MockERC20 internal asset;
    SeraphVault internal vault;
    SeraphShare internal share;
    RewardDistributor internal rewards;
    WithdrawalQueue internal queue;
    StrategyRouter internal router;
    RiskController internal risk;
    FeeController internal fees;

    MockStrategy internal strategyA;
    MockStrategy internal strategyB;

    function setUp() public virtual {
        vm.warp(1_000_000);

        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new SeraphVault(address(asset), address(this), GUARDIAN, 5000);
        share = new SeraphShare("Seraph Yield Share", "syMUSD", 18, address(vault), address(0));
        rewards = new RewardDistributor(
            address(this), GUARDIAN, address(asset), address(share), address(vault)
        );
        queue = new WithdrawalQueue(
            address(this), GUARDIAN, address(vault), WITHDRAWAL_DELAY, CLAIM_WINDOW, 1 hours, 1, 0
        );
        router = new StrategyRouter(address(asset), address(vault), address(this), GUARDIAN);
        risk = new RiskController(
            address(this), GUARDIAN, 10_000_000 * UNIT, 9000, 10_000, UNIT, 1000, 2000
        );
        fees = new FeeController(
            address(this),
            GUARDIAN,
            address(vault),
            FeeConfig({
                performanceFeeBps: 1000,
                managementFeeBps: 0,
                withdrawalFeeBps: 100,
                recipient: TREASURY
            })
        );

        vault.initialize(
            address(share),
            address(rewards),
            address(queue),
            address(router),
            address(risk),
            address(fees)
        );
        vault.setKeeper(KEEPER, true);
        router.setKeeper(address(vault), true);
        router.setKeeper(KEEPER, true);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 sharesMinted) {
        asset.mint(account, assets);
        vm.startPrank(account);
        asset.approve(address(vault), assets);
        sharesMinted = vault.deposit(assets, account);
        vm.stopPrank();
    }

    function _addStrategies() internal {
        strategyA = new MockStrategy(address(asset), address(router), "Conservative Credit");
        strategyB = new MockStrategy(address(asset), address(router), "Liquid Staking");

        router.addStrategy(address(strategyA), STRATEGY_CAP, 1000, 1000);
        router.addStrategy(address(strategyB), STRATEGY_CAP, 1000, 1000);

        address[] memory strategies = new address[](2);
        strategies[0] = address(strategyA);
        strategies[1] = address(strategyB);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        router.setTargetWeights(strategies, weights);
    }

    function _deployIdle() internal returns (uint256 deployed) {
        deployed = vault.deployIdle(type(uint256).max);
    }

    function _harvestBoth() internal returns (uint256 gain, uint256 loss, uint256 debtPayment) {
        address[] memory strategies = new address[](2);
        strategies[0] = address(strategyA);
        strategies[1] = address(strategyB);
        IStrategyRouter.HarvestSummary memory summary = vault.harvest(strategies);
        return (summary.gain, summary.loss, summary.debtPayment);
    }
}
