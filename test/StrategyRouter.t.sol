// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IStrategyRouter } from "../src/interfaces/IStrategyRouter.sol";
import {
    RebalanceAction,
    RebalanceInstruction,
    StrategyConfig,
    StrategyState,
    StrategyStatus
} from "../src/types/SeraphTypes.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract StrategyRouterTest is SeraphTestBase {
    function testGovernorRegistersStrategiesAndSetsWeights() public {
        _addStrategies();

        assertEq(router.strategyCount(), 2);
        assertEq(router.strategyAt(0), address(strategyA));
        assertEq(router.strategyAt(1), address(strategyB));
        assertTrue(router.isRegistered(address(strategyA)));
        assertEq(router.totalTargetWeight(), 10_000);

        StrategyConfig memory first = router.strategyConfig(address(strategyA));
        StrategyConfig memory second = router.strategyConfig(address(strategyB));
        assertEq(first.targetBps, 6000);
        assertEq(second.targetBps, 4000);
        assertEq(uint256(first.status), uint256(StrategyStatus.Active));
    }

    function testDeployIdleAllocatesByTargetWeight() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();

        uint256 deployed = _deployIdle();

        assertEq(deployed, 1800 * UNIT);
        assertEq(asset.balanceOf(address(strategyA)), 1080 * UNIT);
        assertEq(asset.balanceOf(address(strategyB)), 720 * UNIT);
        assertEq(router.totalDebt(), 1800 * UNIT);
        assertEq(vault.idleAssets(), 200 * UNIT);
        assertEq(vault.totalAssets(), 2000 * UNIT);
    }

    function testPullReturnsCapitalToVaultAndReducesDebt() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        (uint256 received, uint256 loss) = vault.pullFromStrategies(300 * UNIT);

        assertEq(received, 300 * UNIT);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(address(strategyA)), 1080 * UNIT);
        assertEq(asset.balanceOf(address(strategyB)), 420 * UNIT);
        assertEq(router.totalDebt(), 1500 * UNIT);
        assertEq(vault.idleAssets(), 500 * UNIT);
        assertEq(vault.totalAssets(), 2000 * UNIT);
    }

    function testHarvestUpdatesReportStateAndSettlesGain() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        asset.mint(address(strategyA), 60 * UNIT);
        asset.mint(address(strategyB), 40 * UNIT);
        address[] memory strategies = new address[](2);
        strategies[0] = address(strategyA);
        strategies[1] = address(strategyB);

        IStrategyRouter.HarvestSummary memory summary = vault.harvest(strategies);
        StrategyState memory stateA = router.strategyState(address(strategyA));
        StrategyState memory stateB = router.strategyState(address(strategyB));

        assertEq(summary.gain, 100 * UNIT);
        assertEq(summary.debtPayment, 100 * UNIT);
        assertEq(stateA.cumulativeGain, 60 * UNIT);
        assertEq(stateB.cumulativeGain, 40 * UNIT);
        assertEq(stateA.reportNonce, 1);
        assertEq(stateB.reportNonce, 1);
        assertEq(router.totalDebt(), 1800 * UNIT);
        assertEq(vault.cumulativeStrategyGain(), 100 * UNIT);
        assertEq(vault.totalAssets(), 2045 * UNIT);
    }

    function testRebalanceMovesCapitalBetweenStrategies() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        RebalanceInstruction[] memory instructions = new RebalanceInstruction[](2);
        instructions[0] = RebalanceInstruction({
            strategy: address(strategyA),
            assets: 180 * UNIT,
            minAssetsOut: 180 * UNIT,
            action: RebalanceAction.Withdraw
        });
        instructions[1] = RebalanceInstruction({
            strategy: address(strategyB),
            assets: 180 * UNIT,
            minAssetsOut: 180 * UNIT,
            action: RebalanceAction.Deposit
        });

        (uint256 deployed, uint256 withdrawn, uint256 loss) = vault.rebalance(instructions);

        assertEq(deployed, 180 * UNIT);
        assertEq(withdrawn, 180 * UNIT);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(address(strategyA)), 900 * UNIT);
        assertEq(asset.balanceOf(address(strategyB)), 900 * UNIT);
        assertEq(router.totalDebt(), 1800 * UNIT);
        assertEq(asset.balanceOf(address(router)), 0);
    }

    function testKeeperCanPullAndHarvestThroughVault() public {
        _deposit(ALICE, 1000 * UNIT);
        _addStrategies();

        vm.prank(KEEPER);
        assertEq(vault.deployIdle(type(uint256).max), 900 * UNIT);

        asset.mint(address(strategyA), 10 * UNIT);
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategyA);
        vm.prank(KEEPER);
        IStrategyRouter.HarvestSummary memory summary = vault.harvest(strategies);

        assertEq(summary.gain, 10 * UNIT);
        assertEq(summary.strategiesReported, 1);
    }
}
