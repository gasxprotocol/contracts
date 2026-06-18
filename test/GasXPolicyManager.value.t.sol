// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { IGasXPolicyManager } from "../src/interfaces/IGasXPolicyManager.sol";

/// @notice B2: the value (stablecoin/x402) ceiling. Strict consumeValue (revert = enforcement); the
///         aggregate valueSpent across N untrusted settler calls can never exceed the one valueBudget.
contract GasXPolicyManagerValueTest is Test {
    GasXPolicyManager internal pm;
    address internal owner = address(this);
    address internal settler = address(0x5E771E4); // the bound settler (e.g. the x402 settlement router)
    address internal token = address(0x05DC); // a stablecoin (informational; amounts are native units)
    address internal guardian = makeAddr("guardian");
    bytes32 internal constant VC = keccak256("vc.alpha");

    function setUp() public {
        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (owner)));
        pm = GasXPolicyManager(address(proxy));
        pm.setGuardian(guardian);
    }

    function _set(uint128 budget) internal {
        pm.setValueCampaign(VC, settler, token, budget, uint48(block.timestamp + 1 days));
    }

    function test_setValueCampaign_then_remaining() public {
        _set(1_000_000); // 1 USDC (6dp)
        IGasXPolicyManager.ValueCampaign memory c = pm.valueCampaignOf(VC);
        assertEq(pm.valueRemaining(VC), 1_000_000);
        assertTrue(c.active);
        assertEq(c.settler, settler);
        assertEq(c.token, token);
        assertEq(c.valueSpent, 0);
    }

    function test_setValueCampaign_is_creation_only() public {
        _set(1_000_000);
        vm.expectRevert(GasXPolicyManager.CampaignExists.selector);
        _set(5_000_000); // no silent overwrite/raise
    }

    function test_setValueCampaign_rejects_zero_settler_or_token() public {
        vm.expectRevert(GasXPolicyManager.ZeroAddress.selector);
        pm.setValueCampaign(VC, address(0), token, 1, 0);
        vm.expectRevert(GasXPolicyManager.ZeroAddress.selector);
        pm.setValueCampaign(VC, settler, address(0), 1, 0);
    }

    function test_consumeValue_only_settler() public {
        _set(1_000_000);
        vm.expectRevert(GasXPolicyManager.NotSettler.selector); // caller (this) is not the settler
        pm.consumeValue(VC, 1);
    }

    function testFuzz_consumeValue_decrements_monotonically(uint128 budget, uint96 a, uint96 b) public {
        budget = uint128(bound(budget, 2, type(uint128).max / 2));
        uint256 amtA = bound(a, 1, budget - 1);
        uint256 amtB = bound(b, 1, budget - amtA);
        _set(budget);
        vm.prank(settler);
        pm.consumeValue(VC, amtA);
        assertEq(pm.valueRemaining(VC), budget - amtA);
        vm.prank(settler);
        pm.consumeValue(VC, amtB);
        assertEq(pm.valueRemaining(VC), budget - amtA - amtB);
    }

    function test_consumeValue_strict_reverts_over_budget() public {
        _set(1_000_000);
        vm.prank(settler);
        vm.expectRevert(GasXPolicyManager.ValueBudgetExceeded.selector);
        pm.consumeValue(VC, 1_000_001);
        assertEq(pm.valueRemaining(VC), 1_000_000, "spent unchanged on revert");
    }

    function test_consumeValue_exhaustion_auto_deactivates() public {
        _set(1_000_000);
        vm.prank(settler);
        pm.consumeValue(VC, 1_000_000);
        assertEq(pm.valueRemaining(VC), 0);
        assertFalse(pm.valueCampaignOf(VC).active, "exhausted value campaign auto-deactivates");
        vm.prank(settler);
        vm.expectRevert(GasXPolicyManager.CampaignInactive.selector);
        pm.consumeValue(VC, 1);
    }

    function test_consumeValue_reverts_after_expiry() public {
        pm.setValueCampaign(VC, settler, token, 1_000_000, uint48(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        vm.prank(settler);
        vm.expectRevert(GasXPolicyManager.CampaignExpired.selector);
        pm.consumeValue(VC, 1);
    }

    function test_consumeValue_fail_closed_when_paused() public {
        _set(1_000_000);
        pm.pause(); // owner may pause
        vm.prank(settler);
        vm.expectRevert(); // EnforcedPause: strict path reverts (fail-closed)
        pm.consumeValue(VC, 1);
    }

    function test_raiseValueBudget_monotonic_up_only() public {
        _set(1_000_000);
        pm.raiseValueBudget(VC, 2_000_000);
        assertEq(pm.valueCampaignOf(VC).valueBudget, 2_000_000);
        vm.expectRevert(GasXPolicyManager.BudgetNotIncreased.selector);
        pm.raiseValueBudget(VC, 2_000_000);
        vm.expectRevert(GasXPolicyManager.BudgetNotIncreased.selector);
        pm.raiseValueBudget(VC, 500_000);
    }

    function test_lowerValueBudget_guardian_only_and_floors_at_spent() public {
        _set(1_000_000);
        vm.prank(settler);
        pm.consumeValue(VC, 300_000); // spent = 300k
        vm.expectRevert(GasXPolicyManager.NotGuardian.selector);
        pm.lowerValueBudget(VC, 500_000); // caller is owner, not guardian
        vm.prank(guardian);
        vm.expectRevert(GasXPolicyManager.InvalidLowerBudget.selector);
        pm.lowerValueBudget(VC, 200_000); // below spent
        vm.prank(guardian);
        pm.lowerValueBudget(VC, 500_000);
        assertEq(pm.valueCampaignOf(VC).valueBudget, 500_000);
    }

    function test_deactivateValue_guardian_or_owner() public {
        _set(1_000_000);
        vm.prank(guardian);
        pm.deactivateValue(VC);
        assertFalse(pm.valueCampaignOf(VC).active);
        pm.reactivateValue(VC); // owner
        assertTrue(pm.valueCampaignOf(VC).active);
    }

    // --- the load-bearing aggregate invariant for VALUE ---
    // Many untrusted settler calls (the agent fleet paying through one router) draw from ONE value
    // budget and can never collectively exceed it; over-budget calls revert (strict).
    function testFuzz_value_aggregate_never_exceeds_budget(uint128 budget, uint96[8] memory amounts) public {
        budget = uint128(bound(budget, 1, type(uint128).max / 2));
        bytes32 id = keccak256("vc.fleet");
        pm.setValueCampaign(id, settler, token, budget, 0);
        uint256 totalCharged;
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(settler);
            try pm.consumeValue(id, amounts[i]) {
                totalCharged += amounts[i];
            } catch { /* over-budget or inactive: strict revert, nothing charged */ }
            assertLe(pm.valueCampaignOf(id).valueSpent, budget, "valueSpent never exceeds the one budget");
        }
        assertLe(totalCharged, budget, "aggregate charged across all settler calls never exceeds the budget");
        assertEq(pm.valueCampaignOf(id).valueSpent, totalCharged, "valueSpent == sum of all charged");
    }
}
