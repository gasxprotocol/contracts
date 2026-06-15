// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { SimpleAccountFactory } from "@account-abstraction/contracts/accounts/SimpleAccountFactory.sol";
import { GasXWhitelistPaymaster } from "../src/core/GasXWhitelistPaymaster.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { GasXPolicyLib } from "../src/libraries/GasXPolicyLib.sol";

contract PingTarget {
    bool public pinged;

    function ping() external {
        pinged = true;
    }
}

/**
 * @title GasX signed-policy fork integration (the A1 end-to-end bridge)
 * @notice On Arbitrum Sepolia (forked) with the live v0.9 EntryPoint: a real EIP-712 SignedApproval from a
 *         registered oracle signer sponsors a UserOp via a real SimpleAccount; postOp decrements the on-chain
 *         campaign budget by actualGasCost; a bare (no-approval) op reverts (no drain); an exhausted budget
 *         caps + auto-deactivates (bounded one-op loss — the off-chain signer is the spend gate).
 * @dev Self-forks via vm.createSelectFork(arbitrum_sepolia); set ARBITRUM_SEPOLIA_RPC_URL to override the RPC.
 */
contract GasXSignedPolicyForkTest is Test {
    address internal constant ENTRYPOINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6; // SimpleAccount.execute(address,uint256,bytes)

    IEntryPoint internal entryPoint = IEntryPoint(ENTRYPOINT_V09);
    SimpleAccountFactory internal factory;
    GasXWhitelistPaymaster internal paymaster;
    GasXPolicyManager internal policy;
    PingTarget internal target;

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant SIGNER_PK = 0x0AC1E5;
    address internal constant BUNDLER = address(0xB0B);
    address internal owner;
    address internal signer;
    bytes32 internal constant C = keccak256("campaign.fork");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("arbitrum_sepolia"));
        assertGt(ENTRYPOINT_V09.code.length, 0, "no v0.9 EntryPoint on the fork");
        owner = vm.addr(OWNER_PK);
        signer = vm.addr(SIGNER_PK);
        target = new PingTarget();

        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this))));
        policy = GasXPolicyManager(address(proxy));

        factory = new SimpleAccountFactory(entryPoint);
        paymaster = new GasXWhitelistPaymaster(entryPoint, address(policy), "GasX", "1");
        paymaster.setLimit(10_000_000, 0);
        paymaster.setSelector(EXECUTE_SELECTOR, true);
        paymaster.setTrustedSigner(signer, true);

        policy.setStrategy(address(paymaster), true);
        policy.setOracleSigner(signer, true);
        policy.setCampaign(C, address(paymaster), 2 ether, uint48(block.timestamp + 1 days));

        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{ value: 2 ether }(address(paymaster));
    }

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

    /// @dev Builds a fully-formed sponsored op: the approval signs the sig-excluded (128B) binding hash; the
    ///      account owner signs the full-pad userOpHash (raw, per SimpleAccount). Returns the op ready to submit.
    function _buildSignedOp(address sender, bytes memory initCode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _baseOp(sender, initCode);
        // 128-byte signed region (NO userOpHash — derived on-chain) at the wire layout the base decodes.
        bytes memory region = abi.encodePacked(
            address(paymaster),
            uint128(300_000),
            uint128(150_000),
            C,
            sender,
            uint256(1 ether), // maxFeeWei
            uint48(0), // validAfter
            type(uint48).max, // validUntil
            bytes32(0) // eligibilityRef
        );
        op.paymasterAndData = region;
        bytes32 bindingHash = entryPoint.getUserOpHash(op); // over the sig-excluded pad
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: sender,
            userOpHash: bindingHash,
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: type(uint48).max,
            eligibilityRef: bytes32(0)
        });
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _ds(), GasXPolicyLib.hash(a)));
        (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(SIGNER_PK, digest);
        op.paymasterAndData = abi.encodePacked(region, abi.encodePacked(ar, as_, av)); // 128B + 65B approval sig

        // account signs the FULL-pad userOpHash (raw — SimpleAccount._validateSignature uses ECDSA.recover(userOpHash,..))
        bytes32 fullHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, fullHash);
        op.signature = abi.encodePacked(r, s, v);
    }

    function _initCode(uint256 salt) internal view returns (address sender, bytes memory initCode) {
        sender = factory.getAddress(owner, salt);
        initCode =
            abi.encodePacked(address(factory), abi.encodeWithSignature("createAccount(address,uint256)", owner, salt));
    }

    function test_sponsored_signed_op_decrements_budget() public {
        (address sender, bytes memory initCode) = _initCode(0);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _buildSignedOp(sender, initCode);

        uint256 spentBefore = policy.campaignOf(C).spentWei;
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, payable(BUNDLER));

        assertTrue(target.pinged(), "inner call did not execute");
        uint256 spent = policy.campaignOf(C).spentWei - spentBefore;
        uint256 charged = depositBefore - entryPoint.balanceOf(address(paymaster));
        assertGt(spent, 0, "campaign budget did not decrement");
        assertGt(charged, 0, "deposit did not decrease");
        assertLe(spent, charged, "consumed (actualGasCost) cannot exceed the total gas charged to the paymaster");
    }

    function test_bare52_op_reverts_without_approval() public {
        // Simple-mode bare 52-byte paymasterAndData (no signed approval) is no longer sponsorable: must revert,
        // proving the legacy 52-byte path cannot drain the deposit.
        (address sender, bytes memory initCode) = _initCode(7);
        PackedUserOperation memory op = _baseOp(sender, initCode);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(300_000), uint128(150_000)); // bare 52
        bytes32 fullHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, fullHash);
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(BUNDLER, BUNDLER);
        vm.expectRevert(); // EntryPoint surfaces InvalidSignedDataLength from validation
        entryPoint.handleOps(ops, payable(BUNDLER));
    }

    function test_exhausted_budget_caps_and_deactivates() public {
        // Valid approval but a 1-wei campaign: postOp consumeUpTo caps at remaining + auto-deactivates; the op
        // STILL succeeds (the paymaster pays that op's gas — the bounded, accepted one-op residual; the
        // off-chain signer is the real spend gate). The budget never goes negative.
        policy.setCampaign(C, address(paymaster), 1, uint48(block.timestamp + 1 days)); // 1 wei budget
        (address sender, bytes memory initCode) = _initCode(2);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _buildSignedOp(sender, initCode);

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, payable(BUNDLER));

        assertTrue(target.pinged(), "op should still execute");
        assertEq(policy.campaignOf(C).spentWei, 1, "spend capped at the 1-wei budget (never negative)");
        assertFalse(policy.campaignOf(C).active, "exhausted campaign auto-deactivated");
    }
}
