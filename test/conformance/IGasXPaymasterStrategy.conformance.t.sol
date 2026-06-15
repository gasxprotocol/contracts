// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { IGasXPaymasterStrategy } from "../../src/interfaces/IGasXPaymasterStrategy.sol";
import { GasXPolicyLib } from "../../src/libraries/GasXPolicyLib.sol";
import { GasXConformancePaymaster, MockGasXPolicyManager } from "../../src/testutils/GasXConformanceHarness.sol";

contract MockEntryPointConf {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function depositTo(address) external payable { }
    function withdrawTo(address payable, uint256) external { }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable { }
    function unlockStake() external { }
    function withdrawStake(address payable) external { }

    function getDepositInfo(address) external pure returns (uint256, bool, uint112, uint32, uint48) {
        return (0, false, 0, 0, 0);
    }

    function getUserOpHash(PackedUserOperation memory op) external pure returns (bytes32) {
        return keccak256(abi.encode(op.sender, op.nonce, op.callData, op.paymasterAndData));
    }
}

/// @notice Behavioral interface conformance suite. ANY IGasXPaymasterStrategy impl must pass: it proves the
///         identity surface AND the validation behavior (valid → sig ok; tampered → SIG_VALIDATION_FAILED;
///         validation performs no PolicyManager read). The `authorizer` (low 160 bits of validationData) is
///         0 on success and 1 on sig-failure per ERC-4337.
abstract contract IGasXPaymasterStrategyConformance is Test {
    IGasXPaymasterStrategy internal subject;
    address internal expectedPolicyManager;
    address internal expectedEntryPoint;

    function _deploy() internal virtual returns (IGasXPaymasterStrategy, address pm_, address ep_);
    function _validate(bool tamper) internal virtual returns (uint256 vd);
    function _validateWithPmReverting() internal virtual returns (uint256 vd);

    function setUp() public virtual {
        (subject, expectedPolicyManager, expectedEntryPoint) = _deploy();
    }

    function test_conf_strategyId_is_nonzero_and_stable() public {
        bytes32 id = subject.strategyId();
        assertTrue(id != bytes32(0), "strategyId must be non-zero");
        assertEq(subject.strategyId(), id, "strategyId must be stable");
    }

    function test_conf_policyManager_is_set() public {
        assertEq(subject.policyManager(), expectedPolicyManager);
    }

    function test_conf_entryPointAddress_is_set() public {
        assertEq(subject.entryPointAddress(), expectedEntryPoint);
    }

    function test_conf_supportsCampaign_is_callable() public view {
        subject.supportsCampaign(keccak256("any"));
    }

    function test_conf_valid_op_authorizes() public {
        assertEq(uint160(_validate(false)), 0, "valid signed approval => authorizer 0 (sig ok)");
    }

    function test_conf_tampered_op_sig_fails() public {
        assertEq(uint160(_validate(true)), 1, "tampered approval => authorizer 1 (SIG_VALIDATION_FAILED)");
    }

    function test_conf_validation_reads_no_policy_manager() public {
        assertEq(
            uint160(_validateWithPmReverting()), 0, "validation must succeed even if PolicyManager reverts on any call"
        );
    }
}

/// @notice Concrete binding: GasXConformancePaymaster (over GasXPaymasterBase) must satisfy the suite.
contract GasXConformancePaymasterConformanceTest is IGasXPaymasterStrategyConformance {
    GasXConformancePaymaster internal strat;
    MockEntryPointConf internal ep;
    MockGasXPolicyManager internal policy;
    uint256 internal constant SIGNER_PK = 0x516;
    bytes32 internal constant C = keccak256("conf.campaign");
    address internal constant SENDER = address(0x5EED);

    function _deploy() internal override returns (IGasXPaymasterStrategy, address, address) {
        ep = new MockEntryPointConf();
        policy = new MockGasXPolicyManager();
        strat = new GasXConformancePaymaster(IEntryPoint(address(ep)), address(policy));
        strat.setTrustedSigner(vm.addr(SIGNER_PK), true);
        return (IGasXPaymasterStrategy(address(strat)), address(policy), address(ep));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GasX")),
                keccak256(bytes("1")),
                block.chainid,
                address(strat)
            )
        );
    }

    function _region(GasXPolicyLib.SignedApproval memory a) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(strat),
            uint128(300_000),
            uint128(150_000),
            a.campaignId,
            a.sender,
            a.maxFeeWei,
            a.validAfter,
            a.validUntil,
            a.eligibilityRef
        );
    }

    function _buildOp(bool tamper) internal view returns (PackedUserOperation memory op) {
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: SENDER,
            userOpHash: bytes32(0),
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: type(uint48).max,
            eligibilityRef: bytes32(uint256(0xE11))
        });
        // bind: userOpHash = EntryPoint hash over the sig-excluded region
        PackedUserOperation memory bindingOp = _emptyOp(_region(a));
        a.userOpHash = ep.getUserOpHash(bindingOp);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        if (tamper) a.campaignId = keccak256("conf.evil"); // region(a) now diverges from the signed message
        op = _emptyOp(abi.encodePacked(_region(a), sig));
    }

    function _emptyOp(bytes memory pad) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: SENDER,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: pad,
            signature: ""
        });
    }

    function _validate(bool tamper) internal override returns (uint256 vd) {
        (, vd) = strat.exposedValidate(_buildOp(tamper), keccak256("op"), 0.5 ether);
    }

    function _validateWithPmReverting() internal override returns (uint256 vd) {
        policy.setReverts(true);
        (, vd) = strat.exposedValidate(_buildOp(false), keccak256("op"), 0.5 ether);
    }
}
