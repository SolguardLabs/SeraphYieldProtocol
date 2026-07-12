// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RiskController } from "../src/core/RiskController.sol";
import { WithdrawalQueue } from "../src/core/WithdrawalQueue.sol";
import { WithdrawalRequest, WithdrawalRound, WithdrawalStatus } from "../src/types/SeraphTypes.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract SeraphWithdrawalsTest is SeraphTestBase {
    function testRequestAndCancelRestoresActiveShares() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(400 * UNIT, ALICE, 390 * UNIT);

        WithdrawalRequest memory requestData = queue.request(requestId);
        assertEq(requestData.owner, ALICE);
        assertEq(requestData.receiver, ALICE);
        assertEq(requestData.shares, 400 * UNIT);
        assertEq(requestData.assetsAtRequest, 396 * UNIT);
        assertEq(requestData.minAssets, 390 * UNIT);
        assertEq(queue.totalQueuedShares(), 400 * UNIT);
        assertEq(queue.queuedSharesOf(ALICE), 400 * UNIT);
        assertEq(share.activeBalanceOf(ALICE), 600 * UNIT);

        vm.prank(ALICE);
        uint256 unlocked = vault.cancelWithdrawal(requestId);

        assertEq(unlocked, 400 * UNIT);
        assertEq(share.activeBalanceOf(ALICE), 1000 * UNIT);
        assertEq(share.lockedBalanceOf(ALICE), 0);
        assertEq(queue.totalQueuedShares(), 0);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Cancelled));
    }

    function testExecuteWithdrawalAfterDelayPaysReceiverAndFee() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(400 * UNIT, CAROL, 390 * UNIT);
        WithdrawalRequest memory requestData = queue.request(requestId);
        vm.warp(requestData.claimableAt);

        vm.prank(KEEPER);
        uint256 assetsReceived = vault.executeWithdrawal(requestId);

        assertEq(assetsReceived, 396 * UNIT);
        assertEq(asset.balanceOf(CAROL), 396 * UNIT);
        assertEq(asset.balanceOf(TREASURY), 4 * UNIT);
        assertEq(share.balanceOf(ALICE), 600 * UNIT);
        assertEq(share.totalSupply(), 1600 * UNIT);
        assertEq(share.totalLocked(), 0);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Claimed));
        assertEq(vault.cumulativeWithdrawals(), 400 * UNIT);

        WithdrawalRound memory roundData = queue.roundInfo(requestData.round);
        assertEq(roundData.sharesProcessed, 400 * UNIT);
        assertEq(roundData.assetsClaimed, 396 * UNIT);
        assertTrue(roundData.closed);
    }

    function testExecutionBeforeDelayReverts() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(100 * UNIT, ALICE, 0);

        vm.expectPartialRevert(WithdrawalQueue.RequestNotReady.selector);
        vault.executeWithdrawal(requestId);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Pending));
    }

    function testMinimumAssetsIsEnforcedAtExecution() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(100 * UNIT, ALICE, 100 * UNIT);
        WithdrawalRequest memory requestData = queue.request(requestId);
        vm.warp(requestData.claimableAt);

        vm.expectPartialRevert(WithdrawalQueue.MinimumAssetsNotMet.selector);
        vault.executeWithdrawal(requestId);

        assertEq(share.lockedBalanceOf(ALICE), 100 * UNIT);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Claimable));
    }

    function testExpiredRequestCannotBeExecutedButCanBeCancelled() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(100 * UNIT, ALICE, 0);
        WithdrawalRequest memory requestData = queue.request(requestId);
        vm.warp(uint256(requestData.expiresAt) + 1);

        vm.expectPartialRevert(WithdrawalQueue.RequestWindowClosed.selector);
        vault.executeWithdrawal(requestId);

        vm.prank(ALICE);
        vault.cancelWithdrawal(requestId);
        assertEq(share.lockedBalanceOf(ALICE), 0);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Cancelled));
    }

    function testOnlyOwnerMayCancelRequest() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(100 * UNIT, ALICE, 0);

        vm.prank(BOB);
        vm.expectPartialRevert(WithdrawalQueue.RequestNotOwned.selector);
        vault.cancelWithdrawal(requestId);
    }

    function testQueueRiskLimitRejectsOversizedAggregateRequest() public {
        _deposit(ALICE, 1000 * UNIT);

        vm.prank(ALICE);
        vm.expectPartialRevert(RiskController.QueueCapacityExceeded.selector);
        vault.requestWithdrawal(901 * UNIT, ALICE, 0);
    }

    function testOwnerRequestPaginationTracksHistory() public {
        _deposit(ALICE, 1000 * UNIT);
        _deposit(BOB, 1000 * UNIT);

        vm.startPrank(ALICE);
        uint256 first = vault.requestWithdrawal(100 * UNIT, ALICE, 0);
        uint256 second = vault.requestWithdrawal(200 * UNIT, CAROL, 0);
        vm.stopPrank();

        assertEq(queue.ownerRequestCount(ALICE), 2);
        assertEq(queue.ownerRequestAt(ALICE, 0), first);
        assertEq(queue.ownerRequestAt(ALICE, 1), second);

        uint256[] memory page = queue.ownerRequests(ALICE, 1, 10);
        assertEq(page.length, 1);
        assertEq(page[0], second);
    }
}
