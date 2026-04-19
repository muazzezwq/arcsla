// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ServiceRegistry } from "../src/ServiceRegistry.sol";
import { IServiceRegistry } from "../src/interfaces/IServiceRegistry.sol";
import { MockUSDC } from "./helpers/MockUSDC.sol";

contract ServiceRegistryTest is Test {
    ServiceRegistry internal registry;
    MockUSDC internal usdc;

    address internal admin = address(0xA11CE);
    address internal provider1 = address(0xB0B);
    address internal provider1Signer = address(0xB0B5);
    address internal payPerCall = address(0xCAFE);
    address internal user = address(0xD00D);

    uint256 internal constant MIN_STAKE = 10e6; // 10 USDC
    uint256 internal constant STAKE = 100e6; // 100 USDC
    uint256 internal constant PRICE = 1e6; // 1 USDC
    uint32 internal constant MAX_RESP = 30; // 30 seconds
    uint32 internal constant SLASH_BPS = 2_000; // 20%

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        registry = new ServiceRegistry(IERC20(address(usdc)), MIN_STAKE);
        registry.setPayPerCall(payPerCall);
        vm.stopPrank();

        // Fund provider1 and approve registry to pull USDC.
        usdc.mint(provider1, 1_000e6);
        vm.prank(provider1);
        usdc.approve(address(registry), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // register
    // ------------------------------------------------------------------

    function test_register_setsState() public {
        vm.prank(provider1);
        uint256 id = registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api.example");

        assertEq(id, 1);
        assertEq(registry.providerIdOf(provider1), 1);

        IServiceRegistry.ProviderView memory p = registry.getProvider(1);
        assertEq(p.owner, provider1);
        assertEq(p.signer, provider1Signer);
        assertEq(p.stake, STAKE);
        assertEq(p.pricePerCall, PRICE);
        assertEq(p.maxResponseTime, MAX_RESP);
        assertEq(p.slashBps, SLASH_BPS);
        assertTrue(p.active);
    }

    function test_register_pullsUSDC() public {
        uint256 balBefore = usdc.balanceOf(provider1);

        vm.prank(provider1);
        registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api");

        assertEq(usdc.balanceOf(provider1), balBefore - STAKE);
        assertEq(usdc.balanceOf(address(registry)), STAKE);
    }

    function test_register_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ServiceRegistry.ProviderRegistered(
            1, provider1, provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api"
        );

        vm.prank(provider1);
        registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api");
    }

    function test_register_twice_reverts() public {
        vm.startPrank(provider1);
        registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "a");

        vm.expectRevert(ServiceRegistry.AlreadyRegistered.selector);
        registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "b");
        vm.stopPrank();
    }

    function test_register_belowMinStake_reverts() public {
        vm.expectRevert(ServiceRegistry.BelowMinStake.selector);
        vm.prank(provider1);
        registry.register(provider1Signer, MIN_STAKE - 1, PRICE, MAX_RESP, SLASH_BPS, "a");
    }

    function test_register_slashBpsOverMax_reverts() public {
        vm.expectRevert(ServiceRegistry.InvalidSlashBps.selector);
        vm.prank(provider1);
        registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, 10_001, "a");
    }

    function test_register_responseTimeTooShort_reverts() public {
        vm.expectRevert(ServiceRegistry.InvalidResponseTime.selector);
        vm.prank(provider1);
        registry.register(provider1Signer, STAKE, PRICE, 4, SLASH_BPS, "a");
    }

    function test_register_zeroSigner_reverts() public {
        vm.expectRevert(ServiceRegistry.InvalidSigner.selector);
        vm.prank(provider1);
        registry.register(address(0), STAKE, PRICE, MAX_RESP, SLASH_BPS, "a");
    }

    // ------------------------------------------------------------------
    // deactivate + unstake
    // ------------------------------------------------------------------

    function test_deactivate_flipsActive() public {
        uint256 id = _registerDefault();

        vm.prank(provider1);
        registry.deactivate(id);

        assertFalse(registry.getProvider(id).active);
    }

    function test_deactivate_notOwner_reverts() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.NotOwner.selector);
        vm.prank(user);
        registry.deactivate(id);
    }

    function test_unstake_afterCooldown_returnsUSDC() public {
        uint256 id = _registerDefault();

        vm.prank(provider1);
        registry.deactivate(id);

        skip(registry.UNSTAKE_COOLDOWN());

        uint256 balBefore = usdc.balanceOf(provider1);
        vm.prank(provider1);
        registry.unstake(id);

        assertEq(usdc.balanceOf(provider1), balBefore + STAKE);
        assertEq(registry.getProvider(id).stake, 0);
    }

    function test_unstake_whileActive_reverts() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.StillActive.selector);
        vm.prank(provider1);
        registry.unstake(id);
    }

    function test_unstake_beforeCooldown_reverts() public {
        uint256 id = _registerDefault();

        vm.prank(provider1);
        registry.deactivate(id);

        // Not waiting → should revert.
        vm.expectRevert(ServiceRegistry.CooldownNotElapsed.selector);
        vm.prank(provider1);
        registry.unstake(id);
    }

    function test_unstake_withPendingCalls_reverts() public {
        uint256 id = _registerDefault();

        vm.prank(provider1);
        registry.deactivate(id);

        vm.prank(payPerCall);
        registry.markCallStarted(id);

        skip(registry.UNSTAKE_COOLDOWN());

        vm.expectRevert(ServiceRegistry.PendingCalls.selector);
        vm.prank(provider1);
        registry.unstake(id);
    }

    // ------------------------------------------------------------------
    // slash (PayPerCall only)
    // ------------------------------------------------------------------

    function test_slash_byPayPerCall_succeeds() public {
        uint256 id = _registerDefault();
        uint256 amount = 20e6;

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(payPerCall);
        registry.slash(id, amount, user);

        assertEq(usdc.balanceOf(user), balBefore + amount);
        assertEq(registry.getProvider(id).stake, STAKE - amount);
    }

    function test_slash_notPayPerCall_reverts() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.OnlyPayPerCall.selector);
        vm.prank(user);
        registry.slash(id, 1e6, user);
    }

    function test_slash_overStake_reverts() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.InsufficientStake.selector);
        vm.prank(payPerCall);
        registry.slash(id, STAKE + 1, user);
    }

    // ------------------------------------------------------------------
    // markCallStarted / markCallFinished hooks
    // ------------------------------------------------------------------

    function test_markCallStarted_onlyPayPerCall() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.OnlyPayPerCall.selector);
        registry.markCallStarted(id);
    }

    function test_markCallFinished_pairsWithStart() public {
        uint256 id = _registerDefault();

        vm.startPrank(payPerCall);
        registry.markCallStarted(id);
        registry.markCallStarted(id);
        assertEq(registry.pendingCalls(id), 2);

        registry.markCallFinished(id);
        assertEq(registry.pendingCalls(id), 1);
        vm.stopPrank();
    }

    function test_markCallFinished_withoutStart_reverts() public {
        uint256 id = _registerDefault();

        vm.expectRevert("no pending");
        vm.prank(payPerCall);
        registry.markCallFinished(id);
    }

    // ------------------------------------------------------------------
    // setPayPerCall (one-time)
    // ------------------------------------------------------------------

    function test_setPayPerCall_twice_reverts() public {
        vm.expectRevert("already set");
        vm.prank(admin);
        registry.setPayPerCall(address(0xBEEF));
    }

    function test_setPayPerCall_notAdmin_reverts() public {
        vm.prank(admin);
        ServiceRegistry fresh = new ServiceRegistry(IERC20(address(usdc)), MIN_STAKE);

        vm.expectRevert(ServiceRegistry.NotOwner.selector);
        vm.prank(user);
        fresh.setPayPerCall(payPerCall);
    }

    // ------------------------------------------------------------------
    // updatePrice / updateSigner
    // ------------------------------------------------------------------

    function test_updatePrice_byOwner() public {
        uint256 id = _registerDefault();
        vm.prank(provider1);
        registry.updatePrice(id, 5e6);
        assertEq(registry.getProvider(id).pricePerCall, 5e6);
    }

    function test_updateSigner_byOwner() public {
        uint256 id = _registerDefault();
        address newSigner = address(0x1234);
        vm.prank(provider1);
        registry.updateSigner(id, newSigner);
        assertEq(registry.getProvider(id).signer, newSigner);
    }

    function test_updateSigner_zero_reverts() public {
        uint256 id = _registerDefault();
        vm.expectRevert(ServiceRegistry.InvalidSigner.selector);
        vm.prank(provider1);
        registry.updateSigner(id, address(0));
    }

    // ------------------------------------------------------------------
    // Reputation (counters + Bayesian score)
    // ------------------------------------------------------------------

    function test_reputation_freshProvider_returns66() public {
        uint256 id = _registerDefault();
        // (0 completed + 2) / (0 + 0 + 2 + 1) × 100 = 66.66… → 66
        assertEq(registry.getReputationScore(id), 66);
    }

    function test_reputation_unknownProvider_returns0() public {
        assertEq(registry.getReputationScore(999), 0);
    }

    function test_incCompleted_onlyPayPerCall() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.OnlyPayPerCall.selector);
        registry.incCompleted(id);
    }

    function test_incSlashed_onlyPayPerCall() public {
        uint256 id = _registerDefault();

        vm.expectRevert(ServiceRegistry.OnlyPayPerCall.selector);
        registry.incSlashed(id);
    }

    function test_incCompleted_bumpsCounterAndEmits() public {
        uint256 id = _registerDefault();

        vm.expectEmit(true, false, false, true);
        emit ServiceRegistry.ReputationUpdated(id, 1, 0);

        vm.prank(payPerCall);
        registry.incCompleted(id);

        assertEq(registry.completedCalls(id), 1);
        assertEq(registry.slashedCalls(id), 0);
    }

    function test_incSlashed_bumpsCounterAndEmits() public {
        uint256 id = _registerDefault();

        vm.expectEmit(true, false, false, true);
        emit ServiceRegistry.ReputationUpdated(id, 0, 1);

        vm.prank(payPerCall);
        registry.incSlashed(id);

        assertEq(registry.slashedCalls(id), 1);
    }

    function test_reputation_afterOneSuccess_returns75() public {
        uint256 id = _registerDefault();
        vm.prank(payPerCall);
        registry.incCompleted(id);
        // (1 + 2) / (1 + 0 + 2 + 1) × 100 = 75
        assertEq(registry.getReputationScore(id), 75);
    }

    function test_reputation_tenSuccesses_reaches92() public {
        uint256 id = _registerDefault();
        vm.startPrank(payPerCall);
        for (uint256 i = 0; i < 10; i++) {
            registry.incCompleted(id);
        }
        vm.stopPrank();
        // (10 + 2) / (10 + 0 + 2 + 1) × 100 = 92.30… → 92
        assertEq(registry.getReputationScore(id), 92);
    }

    function test_reputation_fiveSuccessesOneSlash_returns78() public {
        uint256 id = _registerDefault();
        vm.startPrank(payPerCall);
        for (uint256 i = 0; i < 5; i++) {
            registry.incCompleted(id);
        }
        registry.incSlashed(id);
        vm.stopPrank();
        // (5 + 2) / (5 + 1 + 2 + 1) × 100 = 77.77… → 77
        assertEq(registry.getReputationScore(id), 77);
    }

    function test_reputation_singleSlash_returns50() public {
        uint256 id = _registerDefault();
        vm.prank(payPerCall);
        registry.incSlashed(id);
        // (0 + 2) / (0 + 1 + 2 + 1) × 100 = 50
        assertEq(registry.getReputationScore(id), 50);
    }

    function test_reputation_neverDropsBelowPriorFloor() public {
        uint256 id = _registerDefault();
        vm.startPrank(payPerCall);
        // 100 slashes with 0 completions
        for (uint256 i = 0; i < 100; i++) {
            registry.incSlashed(id);
        }
        vm.stopPrank();
        // (0 + 2) / (0 + 100 + 2 + 1) × 100 = 1.94… → 1
        uint8 score = registry.getReputationScore(id);
        assertLe(score, 5); // very low, but still > 0
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _registerDefault() internal returns (uint256 id) {
        vm.prank(provider1);
        id = registry.register(provider1Signer, STAKE, PRICE, MAX_RESP, SLASH_BPS, "https://api");
    }
}
