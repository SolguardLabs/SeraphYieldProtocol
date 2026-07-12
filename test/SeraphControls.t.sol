// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FeeController } from "../src/core/FeeController.sol";
import { RiskController } from "../src/core/RiskController.sol";
import { SeraphVault } from "../src/core/SeraphVault.sol";
import { StrategyRouter } from "../src/core/StrategyRouter.sol";
import { FeeConfig } from "../src/types/SeraphTypes.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract SeraphControlsTest is SeraphTestBase {
    function testDepositCapIsEnforced() public {
        risk.setDepositCap(1000 * UNIT);
        _deposit(ALICE, 800 * UNIT);

        asset.mint(BOB, 201 * UNIT);
        vm.startPrank(BOB);
        asset.approve(address(vault), 201 * UNIT);
        vm.expectPartialRevert(RiskController.DepositCapExceeded.selector);
        vault.deposit(201 * UNIT, BOB);
        vm.stopPrank();

        assertEq(vault.maxDeposit(BOB), 200 * UNIT);
    }

    function testFeeQuotesAndAnnualizedManagementFee() public {
        FeeConfig memory config = FeeConfig({
            performanceFeeBps: 1500,
            managementFeeBps: 500,
            withdrawalFeeBps: 200,
            recipient: TREASURY
        });
        fees.setFeeConfig(config);

        assertEq(fees.performanceFee(1000 * UNIT), 150 * UNIT);
        assertEq(fees.withdrawalFee(1000 * UNIT), 20 * UNIT);

        vm.warp(block.timestamp + 365 days);
        assertEq(fees.managementFee(1000 * UNIT), 50 * UNIT);
    }

    function testGuardianCanPauseDepositsAndGovernorResumes() public {
        vm.prank(GUARDIAN);
        vault.setDepositPaused(true);

        asset.mint(ALICE, 100 * UNIT);
        vm.startPrank(ALICE);
        asset.approve(address(vault), 100 * UNIT);
        vm.expectRevert(SeraphVault.DepositsPaused.selector);
        vault.deposit(100 * UNIT, ALICE);
        vm.stopPrank();

        vm.prank(GUARDIAN);
        vm.expectRevert(SeraphVault.DepositsPaused.selector);
        vault.setDepositPaused(false);

        vault.setDepositPaused(false);
        vm.prank(ALICE);
        vault.deposit(100 * UNIT, ALICE);
        assertEq(share.balanceOf(ALICE), 100 * UNIT);
    }

    function testProtocolPauseBlocksNewRequests() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(GUARDIAN);
        vault.setProtocolPaused(true);

        vm.prank(ALICE);
        vm.expectRevert(SeraphVault.ProtocolPaused.selector);
        vault.requestWithdrawal(100 * UNIT, ALICE, 0);

        vault.setProtocolPaused(false);
        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(100 * UNIT, ALICE, 0);
        assertEq(requestId, 1);
    }

    function testRouterAllocationPauseBlocksIdleDeployment() public {
        _deposit(ALICE, 1000 * UNIT);
        _addStrategies();

        vm.prank(GUARDIAN);
        router.setRouterPause(true, false);

        vm.expectRevert(StrategyRouter.AllocationsArePaused.selector);
        vault.deployIdle(type(uint256).max);

        router.setRouterPause(false, false);
        assertEq(vault.deployIdle(type(uint256).max), 900 * UNIT);
    }

    function testGuardianCanTightenButNotLoosenQueueLimit() public {
        vm.prank(GUARDIAN);
        risk.tightenQueueLimit(8000);
        assertEq(risk.maxQueuedBps(), 8000);

        vm.prank(GUARDIAN);
        vm.expectRevert(RiskController.InvalidConfiguration.selector);
        risk.tightenQueueLimit(8500);
    }

    function testFeeConfigurationRejectsRatesAboveBounds() public {
        FeeConfig memory invalidConfig = FeeConfig({
            performanceFeeBps: 2001, managementFeeBps: 0, withdrawalFeeBps: 0, recipient: TREASURY
        });

        vm.expectRevert(FeeController.FeeRateTooHigh.selector);
        fees.setFeeConfig(invalidConfig);
    }
}
