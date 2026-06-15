// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IGasXPolicyManager } from "../../src/interfaces/IGasXPolicyManager.sol";
import { GasXPolicyManager } from "../../src/core/GasXPolicyManager.sol";

/// @notice Behavioral interface conformance suite. ANY IGasXPolicyManager impl is interchangeable iff it
///         passes this suite — the bodies are interface-only; a concrete subclass supplies deploy/admin hooks.
abstract contract IGasXPolicyManagerConformance is Test {
    IGasXPolicyManager internal subject;
    address internal strategy = address(0x57A7);
    address internal signer = address(0x516);
    bytes32 internal constant C = keccak256("conf.campaign");

    // --- hooks an implementation must provide ---
    function _deploy() internal virtual returns (IGasXPolicyManager);
    function _allowStrategy(IGasXPolicyManager s, address who) internal virtual;
    function _setCampaign(IGasXPolicyManager s, bytes32 id, address strat, uint128 budget, uint48 endsAt)
        internal
        virtual;
    function _setSigner(IGasXPolicyManager s, address who, bool ok) internal virtual;

    function setUp() public virtual {
        subject = _deploy();
        _allowStrategy(subject, strategy);
        _setSigner(subject, signer, true);
    }

    function test_conf_remaining_equals_budget_initially() public {
        _setCampaign(subject, C, strategy, 7 ether, uint48(block.timestamp + 1 days));
        assertEq(subject.remaining(C), 7 ether);
    }

    function test_conf_consume_is_monotonic_and_bounded() public {
        _setCampaign(subject, C, strategy, 3 ether, uint48(block.timestamp + 1 days));
        vm.prank(strategy);
        subject.consume(C, 1 ether);
        assertEq(subject.remaining(C), 2 ether);
        vm.prank(strategy);
        vm.expectRevert(); // over remaining → revert (fail-closed)
        subject.consume(C, 2 ether + 1);
        assertEq(subject.remaining(C), 2 ether, "remaining never negative");
    }

    function test_conf_consume_only_bound_strategy() public {
        _setCampaign(subject, C, strategy, 1 ether, uint48(block.timestamp + 1 days));
        vm.expectRevert(); // caller is the test, not the campaign's bound strategy
        subject.consume(C, 1);
    }

    function test_conf_consume_auto_deactivates_on_exhaustion() public {
        _setCampaign(subject, C, strategy, 1 ether, uint48(block.timestamp + 1 days));
        vm.prank(strategy);
        subject.consume(C, 1 ether);
        assertEq(subject.remaining(C), 0);
        assertFalse(subject.campaignOf(C).active, "exhausted campaign must be inactive");
        vm.prank(strategy);
        vm.expectRevert(); // inactive
        subject.consume(C, 1);
    }

    function test_conf_consumeUpTo_caps_and_never_reverts_when_inactive() public {
        _setCampaign(subject, C, strategy, 1 ether, uint48(block.timestamp + 1 days));
        vm.prank(strategy);
        assertEq(subject.consumeUpTo(C, 5 ether), 1 ether, "consumeUpTo caps at remaining");
        vm.prank(strategy);
        assertEq(subject.consumeUpTo(C, 1 ether), 0, "inactive consumeUpTo returns 0, never reverts");
    }

    function test_conf_oracle_signer_registry_roundtrip() public {
        assertTrue(subject.isOracleSigner(signer));
        _setSigner(subject, signer, false);
        assertFalse(subject.isOracleSigner(signer));
    }
}

/// @notice Concrete binding: GasXPolicyManager must satisfy the suite (deployed behind its ERC1967 proxy).
contract GasXPolicyManagerConformanceTest is IGasXPolicyManagerConformance {
    function _deploy() internal override returns (IGasXPolicyManager) {
        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this))));
        return IGasXPolicyManager(address(proxy));
    }

    function _allowStrategy(IGasXPolicyManager s, address who) internal override {
        GasXPolicyManager(address(s)).setStrategy(who, true);
    }

    function _setCampaign(IGasXPolicyManager s, bytes32 id, address strat, uint128 b, uint48 e) internal override {
        GasXPolicyManager(address(s)).setCampaign(id, strat, b, e);
    }

    function _setSigner(IGasXPolicyManager s, address who, bool ok) internal override {
        GasXPolicyManager(address(s)).setOracleSigner(who, ok);
    }
}
