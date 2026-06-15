// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { IGasXPolicyManager } from "../src/interfaces/IGasXPolicyManager.sol";

contract GasXPolicyManagerFuzzTest is Test {
    GasXPolicyManager internal pm;
    address internal owner = address(this);
    address internal strategy = address(0x57A7);
    address internal strategy2 = address(0x57A8);
    address internal signer = vm.addr(0x516);
    bytes32 internal constant C = keccak256("campaign.alpha");

    function setUp() public {
        // Production-faithful: deploy impl + ERC1967 proxy; interact via the proxy (impl
        // _disableInitializers prevents direct initialize).
        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (owner)));
        pm = GasXPolicyManager(address(proxy));
        pm.setStrategy(strategy, true);
        pm.setStrategy(strategy2, true);
        pm.setOracleSigner(signer, true);
    }

    function _set(uint128 budget) internal {
        pm.setCampaign(C, strategy, budget, uint48(block.timestamp + 1 days));
    }

    function test_setCampaign_then_remaining() public {
        _set(10 ether);
        assertEq(pm.remaining(C), 10 ether);
        IGasXPolicyManager.Campaign memory c = pm.campaignOf(C);
        assertTrue(c.active);
        assertEq(c.spentWei, 0);
        assertEq(c.strategy, strategy, "campaign bound to its strategy");
    }

    function test_setCampaign_requires_registered_strategy() public {
        vm.expectRevert(GasXPolicyManager.StrategyNotRegistered.selector);
        pm.setCampaign(C, address(0xBADBAD), 1 ether, 0);
    }

    function testFuzz_consume_decrements_monotonically(uint128 budget, uint128 fee1, uint128 fee2) public {
        budget = uint128(bound(budget, 2, type(uint128).max / 2));
        fee1 = uint128(bound(fee1, 1, budget - 1));
        fee2 = uint128(bound(fee2, 1, budget - fee1));
        _set(budget);

        vm.prank(strategy);
        pm.consume(C, fee1);
        assertEq(pm.remaining(C), budget - fee1);

        vm.prank(strategy);
        pm.consume(C, fee2);
        assertEq(pm.remaining(C), budget - fee1 - fee2);
    }

    function test_consume_reverts_when_not_strategy() public {
        _set(1 ether);
        vm.expectRevert(GasXPolicyManager.NotStrategy.selector); // caller (this) is not the bound strategy
        pm.consume(C, 1);
    }

    function test_wrong_strategy_cannot_consume() public {
        _set(1 ether); // bound to `strategy`
        vm.prank(strategy2); // a DIFFERENT registered strategy
        vm.expectRevert(GasXPolicyManager.NotStrategy.selector);
        pm.consume(C, 1);
    }

    function test_consume_reverts_over_budget_and_budget_never_negative() public {
        _set(1 ether);
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.BudgetExceeded.selector);
        pm.consume(C, 1 ether + 1);
        assertEq(pm.remaining(C), 1 ether, "remaining must not underflow");
    }

    function test_consume_exhaustion_auto_deactivates() public {
        _set(1 ether);
        vm.prank(strategy);
        pm.consume(C, 1 ether);
        assertEq(pm.remaining(C), 0);
        assertFalse(pm.campaignOf(C).active, "exhausted campaign must auto-deactivate");
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.CampaignInactive.selector);
        pm.consume(C, 1);
    }

    function test_consume_reverts_when_inactive() public {
        _set(1 ether);
        pm.setActive(C, false);
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.CampaignInactive.selector);
        pm.consume(C, 1);
    }

    function test_consume_reverts_after_endsAt() public {
        pm.setCampaign(C, strategy, 1 ether, uint48(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.CampaignExpired.selector);
        pm.consume(C, 1);
    }

    function test_consumeUpTo_caps_at_remaining_and_auto_deactivates() public {
        _set(1 ether);
        vm.prank(strategy);
        uint256 charged = pm.consumeUpTo(C, 2 ether); // asks more than budget
        assertEq(charged, 1 ether, "must cap at remaining");
        assertEq(pm.remaining(C), 0);
        assertFalse(pm.campaignOf(C).active);
        // a follow-up consumeUpTo on the now-inactive campaign returns 0 (NEVER reverts)
        vm.prank(strategy);
        assertEq(pm.consumeUpTo(C, 1 ether), 0, "inactive consumeUpTo returns 0, no revert");
    }

    function test_consumeUpTo_returns_zero_when_expired_no_revert() public {
        pm.setCampaign(C, strategy, 1 ether, uint48(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        vm.prank(strategy);
        assertEq(pm.consumeUpTo(C, 0.5 ether), 0, "expired consumeUpTo returns 0, no revert");
        assertFalse(pm.campaignOf(C).active, "expired campaign auto-deactivates");
    }

    function testFuzz_onlyOwner_admin(address attacker) public {
        vm.assume(attacker != owner);
        vm.startPrank(attacker);
        vm.expectRevert();
        pm.setCampaign(C, strategy, 1 ether, 0);
        vm.expectRevert();
        pm.setOracleSigner(attacker, true);
        vm.expectRevert();
        pm.setStrategy(attacker, true);
        vm.stopPrank();
    }

    function test_two_step_ownership_transfer() public {
        address newOwner = address(0xA11CE);
        pm.transferOwnership(newOwner);
        assertEq(pm.owner(), owner, "owner unchanged until accept (2-step)");
        vm.prank(newOwner);
        pm.acceptOwnership();
        assertEq(pm.owner(), newOwner, "owner updated after accept");
    }

    function test_isOracleSigner_registry() public {
        assertTrue(pm.isOracleSigner(signer));
        pm.setOracleSigner(signer, false);
        assertFalse(pm.isOracleSigner(signer));
    }

    function test_consume_emits_Consumed_with_remaining() public {
        pm.setCampaign(C, strategy, 5 ether, uint48(block.timestamp + 1 days));
        vm.expectEmit(true, true, false, true, address(pm));
        emit IGasXPolicyManager.Consumed(C, strategy, 2 ether, 3 ether);
        vm.prank(strategy);
        pm.consume(C, 2 ether);
    }
}
