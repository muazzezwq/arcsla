// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ServiceRegistry } from "../src/ServiceRegistry.sol";
import { IServiceRegistry } from "../src/interfaces/IServiceRegistry.sol";
import { PayPerCall } from "../src/PayPerCall.sol";
import { MockUSDC } from "./helpers/MockUSDC.sol";

contract PayPerCallTest is Test {
    using MessageHashUtils for bytes32;

    MockUSDC internal usdc;
    ServiceRegistry internal registry;
    PayPerCall internal payPerCall;

    address internal admin = address(0xA11CE);
    address internal provider1 = address(0xB0B);
    address internal caller = address(0xC0FFEE);

    // Provider signer needs a real private key so we can produce valid ECDSA sigs.
    uint256 internal signerPk = 0xA11CE_BEEF;
    address internal signerAddr;

    uint256 internal constant MIN_STAKE = 10e6;
    uint256 internal constant STAKE = 100e6;
    uint256 internal constant PRICE = 1e6;
    uint32 internal constant MAX_RESP = 30;
    uint32 internal constant SLASH_BPS = 2_000; // 20%
    uint256 internal providerId;

    function setUp() public {
        signerAddr = vm.addr(signerPk);

        vm.startPrank(admin);
        usdc = new MockUSDC();
        registry = new ServiceRegistry(IERC20(address(usdc)), MIN_STAKE);
        payPerCall = new PayPerCall(IERC20(address(usdc)), IServiceRegistry(address(registry)));
        registry.setPayPerCall(address(payPerCall));
        vm.stopPrank();

        // Fund provider and caller, and approve appropriate allowances.
        usdc.mint(provider1, 1_000e6);
        usdc.mint(caller, 1_000e6);

        vm.prank(provider1);
        usdc.approve(address(registry), type(uint256).max);
        vm.prank(caller);
        usdc.approve(address(payPerCall), type(uint256).max);

        // Register a default provider using `signerAddr` as its SLA signer.
        vm.prank(provider1);
        providerId = registry.register(signerAddr, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api");
    }

    // ------------------------------------------------------------------
    // callService — happy path
    // ------------------------------------------------------------------

    function test_callService_escrowsUSDC() public {
        uint256 callerBalBefore = usdc.balanceOf(caller);

        vm.prank(caller);
        payPerCall.callService(providerId, keccak256("request-1"));

        assertEq(usdc.balanceOf(caller), callerBalBefore - PRICE);
        assertEq(usdc.balanceOf(address(payPerCall)), PRICE);
    }

    function test_callService_incrementsPending() public {
        vm.prank(caller);
        payPerCall.callService(providerId, keccak256("r"));

        assertEq(registry.pendingCalls(providerId), 1);
    }

    function test_callService_emitsCallStarted() public {
        // We can't predict the callId ahead of time without replicating the
        // keccak logic, so we record logs and assert specific fields.
        vm.recordLogs();

        vm.prank(caller);
        bytes32 callId = payPerCall.callService(providerId, keccak256("r"));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("CallStarted(bytes32,uint256,address,uint256,bytes32,uint32)")) {
                assertEq(logs[i].topics[1], callId);
                assertEq(uint256(logs[i].topics[2]), providerId);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), caller);
                found = true;
            }
        }
        assertTrue(found, "CallStarted not emitted");
    }

    function test_callService_inactiveProvider_reverts() public {
        vm.prank(provider1);
        registry.deactivate(providerId);

        vm.expectRevert(PayPerCall.ProviderNotActive.selector);
        vm.prank(caller);
        payPerCall.callService(providerId, keccak256("r"));
    }

    // ------------------------------------------------------------------
    // submitReceipt — happy path + sig failures
    // ------------------------------------------------------------------

    function test_submitReceipt_transfersToProvider() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("response-body");

        uint256 providerBalBefore = usdc.balanceOf(provider1);
        bytes memory sig = _sign(signerPk, callId, responseHash);

        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);

        assertEq(usdc.balanceOf(provider1), providerBalBefore + PRICE);
        assertEq(usdc.balanceOf(address(payPerCall)), 0);

        PayPerCall.Call memory c = payPerCall.getCall(callId);
        assertEq(uint8(c.status), uint8(PayPerCall.CallStatus.Completed));
        assertEq(c.responseHash, responseHash);
    }

    function test_submitReceipt_decrementsPending() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);

        assertEq(registry.pendingCalls(providerId), 0);
    }

    function test_submitReceipt_invalidSigner_reverts() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");

        // Sign with the wrong key.
        uint256 wrongPk = 0xDEADBEEF;
        bytes memory sig = _sign(wrongPk, callId, responseHash);

        vm.expectRevert(PayPerCall.InvalidSignature.selector);
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);
    }

    function test_submitReceipt_tamperedHash_reverts() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        // Try to submit a different response hash with the signature meant for another.
        vm.expectRevert(PayPerCall.InvalidSignature.selector);
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, keccak256("different"), sig);
    }

    function test_submitReceipt_afterDeadline_reverts() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        skip(MAX_RESP + 1);

        vm.expectRevert(PayPerCall.DeadlineExceeded.selector);
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);
    }

    function test_submitReceipt_twice_reverts() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);

        vm.expectRevert(PayPerCall.InvalidStatus.selector);
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);
    }

    function test_submitReceipt_updatedSigner_works() public {
        // Provider rotates the signer key, new sigs must use the new key.
        uint256 newPk = 0xFACE_B00C;
        address newSigner = vm.addr(newPk);

        vm.prank(provider1);
        registry.updateSigner(providerId, newSigner);

        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory oldSig = _sign(signerPk, callId, responseHash);
        bytes memory newSig = _sign(newPk, callId, responseHash);

        // Old key must now fail.
        vm.expectRevert(PayPerCall.InvalidSignature.selector);
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, oldSig);

        // New key must succeed.
        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, newSig);

        assertEq(uint8(payPerCall.getCall(callId).status), uint8(PayPerCall.CallStatus.Completed));
    }

    // ------------------------------------------------------------------
    // claimTimeout — refund + slash
    // ------------------------------------------------------------------

    function test_claimTimeout_refundsCaller() public {
        bytes32 callId = _callService(keccak256("r"));

        uint256 callerBalBefore = usdc.balanceOf(caller);
        skip(MAX_RESP + 1);

        vm.prank(caller);
        payPerCall.claimTimeout(callId);

        // Refund (PRICE) + slash (STAKE * SLASH_BPS / 10000 = 20e6)
        uint256 expectedSlash = (STAKE * SLASH_BPS) / 10_000;
        assertEq(usdc.balanceOf(caller), callerBalBefore + PRICE + expectedSlash);
    }

    function test_claimTimeout_reducesStake() public {
        bytes32 callId = _callService(keccak256("r"));
        skip(MAX_RESP + 1);

        vm.prank(caller);
        payPerCall.claimTimeout(callId);

        uint256 expectedSlash = (STAKE * SLASH_BPS) / 10_000;
        assertEq(registry.getProvider(providerId).stake, STAKE - expectedSlash);
    }

    function test_claimTimeout_beforeDeadline_reverts() public {
        bytes32 callId = _callService(keccak256("r"));

        vm.expectRevert(PayPerCall.DeadlineNotReached.selector);
        vm.prank(caller);
        payPerCall.claimTimeout(callId);
    }

    function test_claimTimeout_afterReceipt_reverts() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);

        skip(MAX_RESP + 1);

        vm.expectRevert(PayPerCall.InvalidStatus.selector);
        vm.prank(caller);
        payPerCall.claimTimeout(callId);
    }

    function test_claimTimeout_zeroSlashBps_onlyRefunds() public {
        // New provider with 0 slash bps
        address provider2 = address(0xB0B2);
        uint256 signerPk2 = 0xABCDEF;
        address signer2 = vm.addr(signerPk2);

        usdc.mint(provider2, 1_000e6);
        vm.prank(provider2);
        usdc.approve(address(registry), type(uint256).max);

        vm.prank(provider2);
        uint256 pid = registry.register(signer2, STAKE, PRICE, MAX_RESP, 0, "https://api2");

        vm.prank(caller);
        bytes32 callId = payPerCall.callService(pid, keccak256("r"));

        skip(MAX_RESP + 1);

        uint256 callerBalBefore = usdc.balanceOf(caller);
        vm.prank(caller);
        payPerCall.claimTimeout(callId);

        // Only refund, no slash
        assertEq(usdc.balanceOf(caller), callerBalBefore + PRICE);
        assertEq(registry.getProvider(pid).stake, STAKE);
    }

    function test_claimTimeout_fullSlashBps_transfersAllStake() public {
        address provider3 = address(0xB0B3);
        uint256 signerPk3 = 0xFEEBFEEB;
        address signer3 = vm.addr(signerPk3);

        usdc.mint(provider3, 1_000e6);
        vm.prank(provider3);
        usdc.approve(address(registry), type(uint256).max);

        vm.prank(provider3);
        uint256 pid = registry.register(signer3, STAKE, PRICE, MAX_RESP, 10_000, "https://api3");

        vm.prank(caller);
        bytes32 callId = payPerCall.callService(pid, keccak256("r"));

        skip(MAX_RESP + 1);

        uint256 callerBalBefore = usdc.balanceOf(caller);
        vm.prank(caller);
        payPerCall.claimTimeout(callId);

        assertEq(usdc.balanceOf(caller), callerBalBefore + PRICE + STAKE);
        assertEq(registry.getProvider(pid).stake, 0);
    }

    // ------------------------------------------------------------------
    // Independence — multiple concurrent calls don't interfere
    // ------------------------------------------------------------------

    function test_multipleCallsIndependent() public {
        bytes32 id1 = _callService(keccak256("req-1"));
        bytes32 id2 = _callService(keccak256("req-2"));
        bytes32 id3 = _callService(keccak256("req-3"));

        // All three should be different ids.
        assertTrue(id1 != id2 && id2 != id3 && id1 != id3);
        assertEq(registry.pendingCalls(providerId), 3);

        // Submit receipt for the middle one.
        bytes32 respHash = keccak256("r2-out");
        bytes memory sig = _sign(signerPk, id2, respHash);
        vm.prank(provider1);
        payPerCall.submitReceipt(id2, respHash, sig);

        assertEq(registry.pendingCalls(providerId), 2);

        // Time out the first one.
        skip(MAX_RESP + 1);
        vm.prank(caller);
        payPerCall.claimTimeout(id1);

        assertEq(registry.pendingCalls(providerId), 1);
        assertEq(uint8(payPerCall.getCall(id1).status), uint8(PayPerCall.CallStatus.Slashed));
        assertEq(uint8(payPerCall.getCall(id2).status), uint8(PayPerCall.CallStatus.Completed));
        assertEq(uint8(payPerCall.getCall(id3).status), uint8(PayPerCall.CallStatus.Pending));
    }

    // ------------------------------------------------------------------
    // Reputation integration — PayPerCall must bump the registry counters
    // ------------------------------------------------------------------

    function test_submitReceipt_bumpsCompletedCounter() public {
        bytes32 callId = _callService(keccak256("r"));
        bytes32 responseHash = keccak256("r-out");
        bytes memory sig = _sign(signerPk, callId, responseHash);

        assertEq(registry.completedCalls(providerId), 0);

        vm.prank(provider1);
        payPerCall.submitReceipt(callId, responseHash, sig);

        assertEq(registry.completedCalls(providerId), 1);
        assertEq(registry.slashedCalls(providerId), 0);
        // Reputation: (1+2)/(1+0+3) * 100 = 75
        assertEq(registry.getReputationScore(providerId), 75);
    }

    function test_claimTimeout_bumpsSlashedCounter() public {
        bytes32 callId = _callService(keccak256("r"));
        skip(MAX_RESP + 1);

        assertEq(registry.slashedCalls(providerId), 0);

        vm.prank(caller);
        payPerCall.claimTimeout(callId);

        assertEq(registry.slashedCalls(providerId), 1);
        assertEq(registry.completedCalls(providerId), 0);
        // Reputation: (0+2)/(0+1+3) * 100 = 50
        assertEq(registry.getReputationScore(providerId), 50);
    }

    function test_mixedCalls_buildReputationCorrectly() public {
        // 3 successful calls, 1 slash — provider should end with a realistic score
        for (uint256 i = 0; i < 3; i++) {
            bytes32 cid = _callService(keccak256(abi.encode("req", i)));
            bytes32 rh = keccak256(abi.encode("resp", i));
            bytes memory sig = _sign(signerPk, cid, rh);
            vm.prank(provider1);
            payPerCall.submitReceipt(cid, rh, sig);
        }

        // One more call, don't submit receipt, let it time out
        bytes32 doomed = _callService(keccak256("doomed"));
        skip(MAX_RESP + 1);
        vm.prank(caller);
        payPerCall.claimTimeout(doomed);

        assertEq(registry.completedCalls(providerId), 3);
        assertEq(registry.slashedCalls(providerId), 1);
        // (3+2)/(3+1+3) * 100 = 71
        assertEq(registry.getReputationScore(providerId), 71);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _callService(bytes32 requestHash) internal returns (bytes32 callId) {
        vm.prank(caller);
        callId = payPerCall.callService(providerId, requestHash);
    }

    function _sign(uint256 pk, bytes32 callId, bytes32 responseHash) internal view returns (bytes memory) {
        bytes32 inner = keccak256(abi.encodePacked(callId, responseHash));
        bytes32 digest = inner.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
