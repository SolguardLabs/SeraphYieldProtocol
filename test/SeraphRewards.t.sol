// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RewardDistributor } from "../src/core/RewardDistributor.sol";
import { IStrategyRouter } from "../src/interfaces/IStrategyRouter.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract SeraphRewardsTest is SeraphTestBase {
    function testHarvestNotifiesAndDepositorsClaimRewards() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);
        _addStrategies();
        assertEq(_deployIdle(), 1800 * UNIT);

        asset.mint(address(strategyA), 60 * UNIT);
        asset.mint(address(strategyB), 40 * UNIT);
        address[] memory strategies = new address[](2);
        strategies[0] = address(strategyA);
        strategies[1] = address(strategyB);

        IStrategyRouter.HarvestSummary memory summary = vault.harvest(strategies);

        assertEq(summary.gain, 100 * UNIT);
        assertEq(summary.loss, 0);
        assertEq(summary.debtPayment, 100 * UNIT);
        assertEq(summary.strategiesReported, 2);
        assertEq(rewards.totalRewardsNotified(), 45 * UNIT);
        assertEq(asset.balanceOf(TREASURY), 10 * UNIT);
        assertEq(rewards.previewClaim(ALICE), 22.5e18);
        assertEq(rewards.previewClaim(BOB), 22.5e18);

        vm.prank(ALICE);
        uint256 aliceClaim = vault.claimRewards(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = rewards.claim(BOB);

        assertEq(aliceClaim, 22.5e18);
        assertEq(bobClaim, 22.5e18);
        assertEq(asset.balanceOf(ALICE), 22.5e18);
        assertEq(asset.balanceOf(BOB), 22.5e18);
        assertEq(rewards.totalRewardsClaimed(), 45 * UNIT);
    }

    function testTransfersCheckpointSenderAndReceiver() public {
        _deposit(ALICE, 1000 * UNIT);
        _addStrategies();
        _deployIdle();

        asset.mint(address(strategyA), 100 * UNIT);
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategyA);
        vault.harvest(strategies);

        vm.prank(ALICE);
        assertTrue(share.transfer(BOB, 500 * UNIT));

        asset.mint(address(strategyA), 100 * UNIT);
        vault.harvest(strategies);

        assertEq(rewards.previewClaim(ALICE), 67.5e18);
        assertEq(rewards.previewClaim(BOB), 22.5e18);

        vm.prank(ALICE);
        rewards.claim(ALICE);
        vm.prank(BOB);
        rewards.claim(BOB);

        assertEq(asset.balanceOf(ALICE), 67.5e18);
        assertEq(asset.balanceOf(BOB), 22.5e18);
    }

    function testClaimPauseCanBeAppliedAndRemoved() public {
        _deposit(ALICE, 1000 * UNIT);
        _addStrategies();
        _deployIdle();
        asset.mint(address(strategyA), 100 * UNIT);
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategyA);
        vault.harvest(strategies);

        vm.prank(GUARDIAN);
        rewards.setClaimsPaused(true);

        vm.prank(ALICE);
        vm.expectRevert(RewardDistributor.ClaimsPaused.selector);
        rewards.claim(ALICE);

        rewards.setClaimsPaused(false);
        vm.prank(ALICE);
        assertEq(rewards.claim(ALICE), 45 * UNIT);
    }

    function testZeroRewardClaimIsANoOp() public {
        _deposit(ALICE, 100 * UNIT);

        vm.prank(ALICE);
        assertEq(vault.claimRewards(ALICE), 0);
        assertEq(rewards.totalRewardsClaimed(), 0);
    }
}
