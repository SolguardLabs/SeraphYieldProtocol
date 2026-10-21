// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SeraphPortfolioLens } from "../src/core/SeraphPortfolioLens.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract SeraphPortfolioLensTest is SeraphTestBase {
    SeraphPortfolioLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = new SeraphPortfolioLens(address(vault));
    }

    function testSnapshotTracksIdleDebtAndQueuePressure() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        vm.prank(BOB);
        vault.requestWithdrawal(500 * UNIT, BOB, 0);

        SeraphPortfolioLens.PortfolioSnapshot memory viewState = lens.snapshot();
        assertEq(viewState.totalAssets, 2000 * UNIT);
        assertEq(viewState.idleAssets, 200 * UNIT);
        assertEq(viewState.strategyDebt, 1800 * UNIT);
        assertEq(viewState.activeShares, 1500 * UNIT);
        assertEq(viewState.queuedShares, 500 * UNIT);
        assertEq(viewState.queuedAssetEstimate, 500 * UNIT);
        assertEq(viewState.idleCoverageBps, 4000);
        assertEq(viewState.debtShareBps, 9000);
    }

    function testStrategyExposureAndStressArithmetic() public {
        _deposit(ALICE, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        SeraphPortfolioLens.StrategyExposure[] memory rows = lens.strategies();
        assertEq(rows.length, 2);
        assertEq(rows[0].targetBps + rows[1].targetBps, 10_000);
        assertEq(rows[0].actualDebtBps + rows[1].actualDebtBps, 10_000);

        SeraphPortfolioLens.StressEstimate memory estimate = lens.stress(2000, 5000);
        assertEq(estimate.assetsAfterLoss, 820 * UNIT);
        assertEq(estimate.requestedRedemption, 500 * UNIT);
        assertEq(estimate.idleLiquidityGap, 400 * UNIT);
        assertEq(estimate.totalAssetGap, 0);
    }

    function testStressRejectsRatesBeyondFullExposure() public {
        vm.expectRevert(
            abi.encodeWithSelector(SeraphPortfolioLens.InvalidBasisPoints.selector, 10_001)
        );
        lens.stress(10_001, 0);
        vm.expectRevert(
            abi.encodeWithSelector(SeraphPortfolioLens.InvalidBasisPoints.selector, 10_001)
        );
        lens.stress(0, 10_001);
    }
}
