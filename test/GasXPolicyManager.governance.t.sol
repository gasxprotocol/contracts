// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { IGasXPolicyManager } from "../src/interfaces/IGasXPolicyManager.sol";

/// @notice B0 proof: the risk-direction authority split is real and enforced.
///         OWNER = a TimelockController (delayed, public) can only raise/extend/upgrade.
///         GUARDIAN = the Safe (instant) can only lower/deactivate/pause, never raise, never upgrade.
///         This test IS the evidence behind "the operator cannot raise or replace enforcement
///         unilaterally, silently, or instantly."
contract GasXPolicyManagerGovernanceTest is Test {
    GasXPolicyManager internal pm;
    TimelockController internal timelock;
    address internal safe = makeAddr("safe"); // multisig: timelock proposer/executor AND the guardian
    address internal strategy = address(0x57A7);
    bytes32 internal constant C = keccak256("campaign.alpha");
    uint256 internal constant DELAY = 48 hours;

    function setUp() public {
        address[] memory props = new address[](1);
        props[0] = safe;
        address[] memory execs = new address[](1);
        execs[0] = safe;
        timelock = new TimelockController(DELAY, props, execs, address(0)); // self-administered, no separate admin

        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this))));
        pm = GasXPolicyManager(address(proxy));

        // Configure while this test still owns it, then hand ownership to the timelock.
        pm.setStrategy(strategy, true);
        pm.setGuardian(safe);
        pm.setCampaign(C, strategy, 10 ether, uint48(block.timestamp + 365 days));
        pm.transferOwnership(address(timelock));
        _viaTimelock(abi.encodeWithSignature("acceptOwnership()")); // 2-step accept, executed through the timelock

        assertEq(pm.owner(), address(timelock), "owner is the timelock");
        assertEq(pm.guardian(), safe, "guardian is the safe");
    }

    // schedule -> warp past the delay -> execute a call to `pm` through the timelock (the only owner path)
    function _viaTimelock(bytes memory data) internal {
        vm.prank(safe);
        timelock.schedule(address(pm), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(pm), 0, data, bytes32(0), bytes32(0));
    }

    // --- GUARDIAN: instant safety, never raises ---

    function test_guardian_lowers_instantly() public {
        vm.prank(safe);
        pm.lowerBudget(C, 4 ether);
        assertEq(pm.campaignOf(C).budgetWei, 4 ether, "guardian lowered the cap instantly");
    }

    function test_guardian_pauses_and_deactivates_instantly() public {
        vm.prank(safe);
        pm.pause();
        assertTrue(pm.paused(), "guardian paused instantly");

        vm.prank(safe);
        pm.deactivate(C);
        assertFalse(pm.campaignOf(C).active, "guardian killed the campaign instantly");
    }

    function test_guardian_cannot_raise() public {
        vm.prank(safe);
        vm.expectRevert(); // raiseBudget is onlyOwner==timelock; the guardian/safe is not the owner
        pm.raiseBudget(C, 20 ether);
    }

    function test_guardian_cannot_upgrade() public {
        address v2 = address(new GasXPolicyManager());
        vm.prank(safe);
        vm.expectRevert(); // _authorizeUpgrade is onlyOwner==timelock
        pm.upgradeToAndCall(v2, "");
    }

    // --- OWNER (timelock): raises only after a public delay, never instant ---

    function test_raise_is_not_instant_and_not_direct() public {
        // (a) the Safe cannot raise directly (it is proposer/guardian, not the owner)
        vm.prank(safe);
        vm.expectRevert();
        pm.raiseBudget(C, 20 ether);

        // (b) scheduling a raise does NOT take effect before the delay
        bytes memory data = abi.encodeCall(GasXPolicyManager.raiseBudget, (C, 20 ether));
        vm.prank(safe);
        timelock.schedule(address(pm), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.prank(safe);
        vm.expectRevert(); // operation not ready (delay not elapsed)
        timelock.execute(address(pm), 0, data, bytes32(0), bytes32(0));
        assertEq(pm.campaignOf(C).budgetWei, 10 ether, "budget unchanged within the delay window");

        // (c) only after the public delay does the raise land
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(pm), 0, data, bytes32(0), bytes32(0));
        assertEq(pm.campaignOf(C).budgetWei, 20 ether, "raise lands only after the timelock delay");
    }

    function test_upgrade_only_via_timelock() public {
        address v2 = address(new GasXPolicyManager());
        _viaTimelock(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", v2, bytes("")));
        // still functional after the timelocked upgrade; cap intact
        assertEq(pm.campaignOf(C).budgetWei, 10 ether, "state preserved across the timelocked upgrade");
        assertEq(pm.owner(), address(timelock), "owner preserved");
    }
}
