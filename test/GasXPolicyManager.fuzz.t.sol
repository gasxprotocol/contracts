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
    address internal signer = vm.addr(0x516);
    bytes32 internal constant C = keccak256("campaign.alpha");

    function setUp() public {
        // Production-faithful: deploy the impl + an ERC1967 proxy and interact via the proxy.
        // The impl's constructor calls _disableInitializers(), so initialize() must run through
        // the proxy's delegatecall, not on the impl directly.
        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (owner)));
        pm = GasXPolicyManager(address(proxy));
        pm.setStrategy(strategy, true);
        pm.setOracleSigner(signer, true);
    }

    function test_setCampaign_then_remaining() public {
        pm.setCampaign(C, 10 ether, uint48(block.timestamp + 1 days));
        assertEq(pm.remaining(C), 10 ether);
        IGasXPolicyManager.Campaign memory c = pm.campaignOf(C);
        assertTrue(c.active);
        assertEq(c.spentWei, 0);
    }

    function testFuzz_consume_decrements_monotonically(uint128 budget, uint128 fee1, uint128 fee2) public {
        budget = uint128(bound(budget, 2, type(uint128).max / 2));
        fee1 = uint128(bound(fee1, 1, budget - 1));
        fee2 = uint128(bound(fee2, 1, budget - fee1));
        pm.setCampaign(C, budget, uint48(block.timestamp + 1 days));

        vm.prank(strategy);
        pm.consume(C, fee1);
        assertEq(pm.remaining(C), budget - fee1);

        vm.prank(strategy);
        pm.consume(C, fee2);
        assertEq(pm.remaining(C), budget - fee1 - fee2);
    }

    function test_consume_reverts_when_not_strategy() public {
        pm.setCampaign(C, 1 ether, uint48(block.timestamp + 1 days));
        vm.expectRevert(GasXPolicyManager.NotStrategy.selector);
        pm.consume(C, 1);
    }

    function test_consume_reverts_over_budget_and_budget_never_negative() public {
        pm.setCampaign(C, 1 ether, uint48(block.timestamp + 1 days));
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.BudgetExceeded.selector);
        pm.consume(C, 1 ether + 1);
        assertEq(pm.remaining(C), 1 ether, "remaining must not underflow");
    }

    function test_consume_exhaustion_auto_deactivates() public {
        pm.setCampaign(C, 1 ether, uint48(block.timestamp + 1 days));
        vm.prank(strategy);
        pm.consume(C, 1 ether);
        assertEq(pm.remaining(C), 0);
        assertFalse(pm.campaignOf(C).active, "exhausted campaign must auto-deactivate");
        // a follow-up consume on an inactive campaign reverts
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.CampaignInactive.selector);
        pm.consume(C, 1);
    }

    function test_consume_reverts_when_inactive() public {
        pm.setCampaign(C, 1 ether, uint48(block.timestamp + 1 days));
        pm.setActive(C, false);
        vm.prank(strategy);
        vm.expectRevert(GasXPolicyManager.CampaignInactive.selector);
        pm.consume(C, 1);
    }

    function testFuzz_onlyOwner_admin(address attacker) public {
        vm.assume(attacker != owner);
        vm.startPrank(attacker);
        vm.expectRevert();
        pm.setCampaign(C, 1 ether, 0);
        vm.expectRevert();
        pm.setOracleSigner(attacker, true);
        vm.expectRevert();
        pm.setStrategy(attacker, true);
        vm.stopPrank();
    }

    function test_isOracleSigner_registry() public {
        assertTrue(pm.isOracleSigner(signer));
        pm.setOracleSigner(signer, false);
        assertFalse(pm.isOracleSigner(signer));
    }

    function test_consume_emits_Consumed_with_remaining() public {
        pm.setCampaign(C, 5 ether, uint48(block.timestamp + 1 days));
        vm.expectEmit(true, true, false, true, address(pm));
        emit IGasXPolicyManager.Consumed(C, strategy, 2 ether, 3 ether);
        vm.prank(strategy);
        pm.consume(C, 2 ether);
    }
}
