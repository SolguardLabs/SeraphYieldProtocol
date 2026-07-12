// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SeraphShare } from "../src/token/SeraphShare.sol";
import { WithdrawalStatus } from "../src/types/SeraphTypes.sol";
import { SeraphTestBase } from "./SeraphTestBase.sol";

contract SeraphShareTest is SeraphTestBase {
    function testInitializesAllModulesAndTokenMetadata() public view {
        assertTrue(vault.initialized());
        assertEq(vault.asset(), address(asset));
        assertEq(address(vault.share()), address(share));
        assertEq(address(vault.rewards()), address(rewards));
        assertEq(address(vault.withdrawalQueue()), address(queue));
        assertEq(address(vault.strategyRouter()), address(router));
        assertEq(address(vault.riskController()), address(risk));
        assertEq(address(vault.feeController()), address(fees));

        assertEq(share.name(), "Seraph Yield Share");
        assertEq(share.symbol(), "syMUSD");
        assertEq(share.decimals(), 18);
        assertEq(share.vault(), address(vault));
        assertEq(share.queue(), address(queue));
        assertEq(address(share.transferHook()), address(rewards));
    }

    function testTwoDepositorsReceiveProportionalShares() public {
        uint256 aliceShares = _deposit(ALICE, 750 * UNIT);
        uint256 bobShares = _deposit(BOB, 250 * UNIT);

        assertEq(aliceShares, 750 * UNIT);
        assertEq(bobShares, 250 * UNIT);
        assertEq(share.balanceOf(ALICE), 750 * UNIT);
        assertEq(share.balanceOf(BOB), 250 * UNIT);
        assertEq(share.totalSupply(), 1000 * UNIT);
        assertEq(vault.totalAssets(), 1000 * UNIT);
        assertEq(vault.convertToAssets(share.totalSupply()), 1000 * UNIT);
    }

    function testTransferAndTransferFromMoveOnlyActiveShares() public {
        _deposit(ALICE, 1000 * UNIT);

        vm.prank(ALICE);
        assertTrue(share.transfer(BOB, 200 * UNIT));
        assertEq(share.balanceOf(ALICE), 800 * UNIT);
        assertEq(share.balanceOf(BOB), 200 * UNIT);

        vm.prank(ALICE);
        share.approve(CAROL, 150 * UNIT);
        vm.prank(CAROL);
        assertTrue(share.transferFrom(ALICE, BOB, 150 * UNIT));

        assertEq(share.balanceOf(ALICE), 650 * UNIT);
        assertEq(share.balanceOf(BOB), 350 * UNIT);
        assertEq(share.allowance(ALICE, CAROL), 0);
    }

    function testPermitSetsAllowanceAndIncrementsNonce() public {
        uint256 ownerKey = 0xA11CE123;
        address owner = vm.addr(ownerKey);
        _deposit(owner, 100 * UNIT);

        uint256 value = 25 * UNIT;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(share.PERMIT_TYPEHASH(), owner, BOB, value, share.nonces(owner), deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", share.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.prank(BOB);
        share.permit(owner, BOB, value, deadline, v, r, s);

        assertEq(share.allowance(owner, BOB), value);
        assertEq(share.nonces(owner), 1);

        vm.prank(BOB);
        assertTrue(share.transferFrom(owner, BOB, value));
        assertEq(share.balanceOf(BOB), value);
    }

    function testWithdrawalRequestLocksTransferCapacity() public {
        _deposit(ALICE, 1000 * UNIT);

        vm.prank(ALICE);
        uint256 requestId = vault.requestWithdrawal(600 * UNIT, ALICE, 0);

        assertEq(share.balanceOf(ALICE), 1000 * UNIT);
        assertEq(share.lockedBalanceOf(ALICE), 600 * UNIT);
        assertEq(share.activeBalanceOf(ALICE), 400 * UNIT);
        assertEq(share.totalLocked(), 600 * UNIT);
        assertEq(uint256(queue.statusOf(requestId)), uint256(WithdrawalStatus.Pending));

        vm.prank(ALICE);
        vm.expectPartialRevert(SeraphShare.InsufficientActiveBalance.selector);
        // The return value is unreachable because this call is expected to revert.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        share.transfer(BOB, 401 * UNIT);

        vm.prank(ALICE);
        assertTrue(share.transfer(BOB, 400 * UNIT));
        assertEq(share.activeBalanceOf(ALICE), 0);
        assertEq(share.activeBalanceOf(BOB), 400 * UNIT);
    }
}
