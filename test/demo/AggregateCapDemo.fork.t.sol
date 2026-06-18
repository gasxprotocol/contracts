// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { SimpleAccountFactory } from "@account-abstraction/contracts/accounts/SimpleAccountFactory.sol";
import { GasXWhitelistPaymaster } from "../../src/core/GasXWhitelistPaymaster.sol";
import { GasXPolicyManager } from "../../src/core/GasXPolicyManager.sol";
import { IGasXPolicyManager } from "../../src/interfaces/IGasXPolicyManager.sol";
import { GasXPolicyLib } from "../../src/libraries/GasXPolicyLib.sol";

contract PingTarget {
    function ping() external { }
}

/**
 * @title  AggregateCapDemo (the GTM artifact, runnable)
 * @notice The 3-wallets-one-ceiling proof, end-to-end against the real v0.9 EntryPoint on a forked
 *         Arbitrum Sepolia: THREE distinct smart accounts (an "agent fleet") each pass their own
 *         per-op limit, but they all draw down ONE sponsor-set campaign budget. The on-chain spend can
 *         NEVER exceed that budget (consumeUpTo caps + auto-deactivates) — no incumbent combines
 *         sponsor-set + aggregate-across-untrusted-wallets + on-chain enforcement. The companion test
 *         shows the risk-direction split: a RAISE is timelocked (delayed, public), while the guardian
 *         LOWERS/pauses instantly.
 *
 * @dev    Run: forge test --match-contract AggregateCapDemo -vv  (self-forks Arbitrum Sepolia for the
 *         real EntryPoint; deploys a fresh, deterministic stack so it needs no live state or keys).
 */
contract AggregateCapDemo is Test {
    address internal constant ENTRYPOINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    IEntryPoint internal entryPoint = IEntryPoint(ENTRYPOINT_V09);
    SimpleAccountFactory internal factory;
    GasXWhitelistPaymaster internal paymaster;
    GasXPolicyManager internal policy;
    TimelockController internal timelock;
    PingTarget internal target;

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant SIGNER_PK = 0x0AC1E5;
    address internal constant BUNDLER = address(0xB0B);
    address internal owner = vm.addr(OWNER_PK);
    address internal signer = vm.addr(SIGNER_PK);
    address internal guardian = makeAddr("guardian"); // distinct instant-kill key
    bytes32 internal constant C = keccak256("campaign.demo.fleet");
    uint48 internal constant MAXT = type(uint48).max;
    uint256 internal constant DELAY = 1 hours;

    // sized for ~2.4 sponsored ops (per-op ~0.00033 ETH on the fork) so the 3rd wallet is the one capped.
    uint128 internal constant BUDGET = 0.0008 ether;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("arbitrum_sepolia"));
        assertGt(ENTRYPOINT_V09.code.length, 0, "no v0.9 EntryPoint on the fork");
        target = new PingTarget();
        factory = new SimpleAccountFactory(entryPoint);

        GasXPolicyManager impl = new GasXPolicyManager();
        policy = GasXPolicyManager(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this)))))
        );
        paymaster = new GasXWhitelistPaymaster(entryPoint, address(policy), "GasX", "1");
        paymaster.setLimit(10_000_000, 0);
        paymaster.setSelector(0xb61d27f6, true); // execute(address,uint256,bytes)
        paymaster.setTrustedSigner(signer, true);

        policy.setStrategy(address(paymaster), true);
        policy.setOracleSigner(signer, true);
        policy.setGuardian(guardian);
        policy.setCampaign(C, address(paymaster), BUDGET, uint48(block.timestamp + 30 days));

        // hand ownership to a timelock (this test is proposer+executor so it can drive the demo).
        address[] memory ctrl = new address[](1);
        ctrl[0] = address(this);
        timelock = new TimelockController(DELAY, ctrl, ctrl, address(0));
        policy.transferOwnership(address(timelock));
        _viaTimelock(abi.encodeWithSignature("acceptOwnership()"));
        assertEq(policy.owner(), address(timelock), "owner is the timelock");

        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{ value: 2 ether }(address(paymaster));
    }

    function _viaTimelock(bytes memory data) internal {
        timelock.schedule(address(policy), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(policy), 0, data, bytes32(0), bytes32(0));
    }

    // --- THE DEMO: three distinct wallets, one ceiling ---
    function test_three_wallets_share_one_ceiling() public {
        console2.log("Campaign budget (one shared ceiling, wei):", uint256(BUDGET));
        string[3] memory names = ["A", "B", "C"];
        uint256 lastRemaining = BUDGET;

        for (uint256 i = 0; i < 3; i++) {
            (address sender, bytes memory initCode) = _initCode(i);
            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = _buildSignedOp(sender, initCode);

            bool activeBefore = policy.campaignOf(C).active;
            uint256 spentBefore = policy.campaignOf(C).spentWei;

            vm.prank(BUNDLER, BUNDLER);
            entryPoint.handleOps(ops, payable(BUNDLER));

            IGasXPolicyManager.Campaign memory c = policy.campaignOf(C);
            uint256 charged = c.spentWei - spentBefore;
            console2.log(string.concat("Wallet ", names[i], " (distinct account):"), sender);
            console2.log("   charged to the shared budget (wei):", charged);
            console2.log("   remaining (wei):", policy.remaining(C));
            console2.log("   campaign still active?", c.active);

            // THE INVARIANT: the aggregate on-chain spend never exceeds the one budget.
            assertLe(c.spentWei, BUDGET, "aggregate spent must never exceed the shared budget");
            assertLe(policy.remaining(C), lastRemaining, "remaining is monotonic down across untrusted wallets");
            lastRemaining = policy.remaining(C);
            if (!activeBefore) assertEq(charged, 0, "an exhausted campaign sponsors nothing further");
        }

        IGasXPolicyManager.Campaign memory fin = policy.campaignOf(C);
        assertLe(fin.spentWei, BUDGET, "final aggregate spend <= budget");
        assertEq(fin.active, fin.spentWei < BUDGET, "campaign auto-deactivates exactly when the budget is exhausted");
        console2.log("RESULT: 3 untrusted wallets drew from ONE budget; on-chain spent never exceeded it.");
    }

    // --- THE KICKER: raise is timelocked (delayed+public), guardian lowers/pauses instantly ---
    function test_raise_is_delayed_but_guardian_is_instant() public {
        uint128 startBudget = policy.campaignOf(C).budgetWei;

        // operator queues a RAISE through the timelock: it does NOT take effect immediately.
        bytes memory raise = abi.encodeCall(GasXPolicyManager.raiseBudget, (C, startBudget + 1 ether));
        timelock.schedule(address(policy), 0, raise, bytes32(0), bytes32(0), DELAY);
        assertEq(policy.campaignOf(C).budgetWei, startBudget, "raise is NOT instant: budget unchanged while queued");
        console2.log("Operator queued a RAISE -> budget still", uint256(policy.campaignOf(C).budgetWei), "(delayed, public)");

        // meanwhile the guardian LOWERS instantly (and can pause), with no delay and no timelock.
        vm.prank(guardian);
        policy.lowerBudget(C, startBudget / 2);
        assertEq(policy.campaignOf(C).budgetWei, startBudget / 2, "guardian lowered the ceiling instantly");
        console2.log("Guardian LOWERED instantly -> budget now", uint256(policy.campaignOf(C).budgetWei));
        vm.prank(guardian);
        policy.pause();
        assertTrue(policy.paused(), "guardian paused instantly (kill switch; unpause is owner-only by design)");

        // the raise only lands after the public delay (raiseBudget is not blocked by pause).
        vm.warp(block.timestamp + DELAY);
        timelock.execute(address(policy), 0, raise, bytes32(0), bytes32(0));
        assertEq(policy.campaignOf(C).budgetWei, startBudget + 1 ether, "raise lands only after the timelock delay");
        console2.log("RESULT: raise required a public delay; guardian lower/pause were instant. Risk-direction split holds.");
    }

    // --- helpers (mirror the live-fork signed-policy path) ---
    function _ds() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GasX")),
                keccak256(bytes("1")),
                block.chainid,
                address(paymaster)
            )
        );
    }

    function _baseOp(address sender, bytes memory initCode) internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: initCode,
            callData: abi.encodeWithSignature(
                "execute(address,uint256,bytes)", address(target), uint256(0), abi.encodeWithSignature("ping()")
            ),
            accountGasLimits: bytes32((uint256(1_500_000) << 128) | uint256(300_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _buildSignedOp(address sender, bytes memory initCode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _baseOp(sender, initCode);
        bytes memory region = abi.encodePacked(
            address(paymaster), uint128(300_000), uint128(150_000), C, sender, uint256(1 ether), uint48(0), MAXT, bytes32(0)
        );
        op.paymasterAndData = region;
        bytes32 bindingHash = entryPoint.getUserOpHash(op);
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: sender,
            userOpHash: bindingHash,
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: MAXT,
            eligibilityRef: bytes32(0)
        });
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _ds(), GasXPolicyLib.hash(a)));
        (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(SIGNER_PK, digest);
        op.paymasterAndData = abi.encodePacked(region, abi.encodePacked(ar, as_, av));
        bytes32 fullHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, fullHash);
        op.signature = abi.encodePacked(r, s, v);
    }

    function _initCode(uint256 salt) internal view returns (address sender, bytes memory initCode) {
        sender = factory.getAddress(owner, salt);
        initCode =
            abi.encodePacked(address(factory), abi.encodeWithSignature("createAccount(address,uint256)", owner, salt));
    }
}
