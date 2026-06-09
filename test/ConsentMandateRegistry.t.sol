// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConsentMandateRegistry} from "../src/ConsentMandateRegistry.sol";

contract ConsentMandateRegistryTest is Test {
    ConsentMandateRegistry registry;

    // Stable test accounts.
    uint256 internal recipientKey = 0xA11CE;
    uint256 internal agentKey = 0xBEEF;
    address internal recipient;
    address internal agent;
    address internal buyer = address(0xB07E1);
    address internal seller = address(0x5E11E);

    function setUp() public {
        recipient = vm.addr(recipientKey);
        agent = vm.addr(agentKey);
        registry = new ConsentMandateRegistry(seller);
    }

    function _mandate() internal view returns (ConsentMandateRegistry.Mandate memory m) {
        m.recipient = recipient;
        m.authorizedAgent = agent;
        m.buyerWallet = buyer;
        m.phoneHash = keccak256(bytes("+15551234567"));
        m.maxMessages = 50;
        m.maxUsdc = 1_500_000; // $1.50 in 6-decimal USDC
        m.notBefore = uint64(block.timestamp);
        m.expiresAt = uint64(block.timestamp + 30 days);
        m.nonce = 1;
    }

    function _sign(ConsentMandateRegistry.Mandate memory m) internal view returns (bytes memory) {
        bytes32 digest = registry.getMandateId(m);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(recipientKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_registerMandate_succeeds() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);

        bytes32 mandateId = registry.registerMandate(m, sig);

        (bool registered, bool revoked, uint128 spentMessages, uint128 spentUsdc) =
            registry.mandates(mandateId);
        assertTrue(registered);
        assertFalse(revoked);
        assertEq(spentMessages, 0);
        assertEq(spentUsdc, 0);
    }

    function test_registerMandate_rejectsBadSignature() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes32 digest = registry.getMandateId(m);
        // Sign with the wrong key (the agent, not the recipient).
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(ConsentMandateRegistry.InvalidSignature.selector);
        registry.registerMandate(m, badSig);
    }

    function test_registerMandate_rejectsReplay() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);
        registry.registerMandate(m, sig);

        // Same nonce → reject.
        vm.expectRevert(ConsentMandateRegistry.NonceAlreadyUsed.selector);
        registry.registerMandate(m, sig);
    }

    function test_recordSpend_succeeds() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);
        bytes32 mandateId = registry.registerMandate(m, sig);

        vm.prank(seller);
        registry.recordSpend(mandateId, 5, 150_000, m.maxMessages, m.maxUsdc);

        (, , uint128 spentMessages, uint128 spentUsdc) = registry.mandates(mandateId);
        assertEq(spentMessages, 5);
        assertEq(spentUsdc, 150_000);
    }

    function test_recordSpend_capsEnforced() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);
        bytes32 mandateId = registry.registerMandate(m, sig);

        vm.prank(seller);
        vm.expectRevert(ConsentMandateRegistry.CapExceededMessages.selector);
        registry.recordSpend(mandateId, 51, 0, m.maxMessages, m.maxUsdc);
    }

    function test_recordSpend_onlySeller() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);
        bytes32 mandateId = registry.registerMandate(m, sig);

        vm.expectRevert(ConsentMandateRegistry.OnlySeller.selector);
        registry.recordSpend(mandateId, 1, 30_000, m.maxMessages, m.maxUsdc);
    }

    function test_revoke_blocksFurtherSpend() public {
        ConsentMandateRegistry.Mandate memory m = _mandate();
        bytes memory sig = _sign(m);
        bytes32 mandateId = registry.registerMandate(m, sig);

        registry.revokeMandate(mandateId);

        vm.prank(seller);
        vm.expectRevert(ConsentMandateRegistry.MandateRevoked_.selector);
        registry.recordSpend(mandateId, 1, 30_000, m.maxMessages, m.maxUsdc);
    }
}
