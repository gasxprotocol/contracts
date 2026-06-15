// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { _packValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { GasXERC20FeePaymaster, IGasXPriceOracle } from "../src/core/GasXERC20FeePaymaster.sol";
import { TestableGasXERC20 } from "../src/testutils/TestableGasXERC20.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { GasXPolicyLib } from "../src/libraries/GasXPolicyLib.sol";

contract MockEP {
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

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 d) ERC20("Mock", "MOCK") {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("FeeOnXfer", "FOT") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    // 1% of every transfer is skimmed to a sink => recipient receives 99%.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            if (fee > 0) super._update(from, address(0xFEE), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract MockOracle is IGasXPriceOracle {
    uint256 public price;
    bool public reverts;

    function set(uint256 p) external {
        price = p;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function computeQuoteAverage(uint256, address, address) external view returns (uint256) {
        require(!reverts, "oracle down");
        return price;
    }
}

contract GasXERC20FeePaymasterTest is Test {
    TestableGasXERC20 internal pm;
    GasXPolicyManager internal policy;
    MockEP internal ep;
    MockToken internal token;
    MockOracle internal oracle;

    uint256 internal constant SIGNER_PK = 0x516;
    address internal signer;
    bytes32 internal constant C = keccak256("campaign.erc20");
    bytes32 internal constant OP_HASH = keccak256("op.alpha");
    address internal constant SENDER = address(0x5EED);
    address internal constant BASE_TOKEN = address(0x1111);
    uint48 internal constant MAXT = type(uint48).max;
    uint256 internal constant GAS = 1 ether; // actualGasCost; fee = GAS*price/1e18 = price (clean math)
    uint256 internal constant PRICE = 1000e6; // signer-committed feeToken units per 1e18 wei gas

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        ep = new MockEP();
        token = new MockToken(6);
        oracle = new MockOracle();
        oracle.set(PRICE); // oracle agrees with the signer by default (no clamp)

        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this))));
        policy = GasXPolicyManager(address(proxy));

        pm = new TestableGasXERC20(
            IEntryPoint(address(ep)), address(policy), "GasX", "1", address(token), address(oracle), BASE_TOKEN
        );
        pm.setTrustedSigner(signer, true);

        policy.setStrategy(address(pm), true);
        policy.setCampaign(C, address(pm), 10 ether, uint48(block.timestamp + 1 days));

        token.mint(SENDER, 1_000_000e6);
        vm.prank(SENDER);
        token.approve(address(pm), type(uint256).max);
    }

    function _region(GasXPolicyLib.SignedApproval memory a) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pm),
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

    function _signedOp(uint256 price) internal view returns (PackedUserOperation memory op) {
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: SENDER,
            userOpHash: bytes32(0),
            maxFeeWei: 2 ether,
            validAfter: 0,
            validUntil: MAXT,
            eligibilityRef: bytes32(price) // signer commits the token price here
        });
        PackedUserOperation memory bindingOp = _op(_region(a));
        a.userOpHash = ep.getUserOpHash(bindingOp);
        bytes32 ds = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GasX")),
                keccak256(bytes("1")),
                block.chainid,
                address(pm)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        op = _op(abi.encodePacked(_region(a), abi.encodePacked(r, s, v)));
    }

    function _op(bytes memory pad) internal pure returns (PackedUserOperation memory) {
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

    function test_validation_authorizes_and_carries_price() public {
        (bytes memory ctx, uint256 vd) = pm.exposedValidate(_signedOp(PRICE), OP_HASH, 1 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0), "valid signed approval");
        (, address sender,, uint256 price) = abi.decode(ctx, (bytes32, address, bytes32, uint256));
        assertEq(sender, SENDER);
        assertEq(price, PRICE, "context carries the signed token price");
    }

    function test_validation_does_not_read_oracle() public {
        oracle.setReverts(true); // any oracle read in validation would revert
        (, uint256 vd) = pm.exposedValidate(_signedOp(PRICE), OP_HASH, 1 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0), "validation must not read the oracle");
    }

    function test_pause_blocks_validation() public {
        PackedUserOperation memory op = _signedOp(PRICE);
        pm.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pm.exposedValidate(op, OP_HASH, 1 ether);
    }

    function test_postOp_charges_fee_and_consumes_budget() public {
        (bytes memory ctx,) = pm.exposedValidate(_signedOp(PRICE), OP_HASH, 1 ether);
        uint256 balBefore = token.balanceOf(address(pm));
        pm.exposedPostOp(ctx, GAS, 1 gwei);
        assertEq(token.balanceOf(address(pm)) - balBefore, PRICE, "fee == GAS*price/1e18 == price");
        assertEq(pm.totalFeesCollected(), PRICE);
        assertEq(policy.remaining(C), 10 ether - GAS, "ETH budget consumed by actualGasCost");
    }

    function test_postOp_oracle_clamps_overpriced_signer() public {
        // signer commits 2x the oracle price; postOp clamps to oraclePrice * 1.05
        (bytes memory ctx,) = pm.exposedValidate(_signedOp(2 * PRICE), OP_HASH, 1 ether);
        uint256 balBefore = token.balanceOf(address(pm));
        pm.exposedPostOp(ctx, GAS, 1 gwei);
        uint256 cap = (PRICE * (10_000 + pm.PRICE_DEVIATION_BPS())) / 10_000; // PRICE * 1.05
        assertEq(token.balanceOf(address(pm)) - balBefore, cap, "fee clamped to oracle + deviation");
    }

    function test_postOp_charge_failure_does_not_revert() public {
        (bytes memory ctx,) = pm.exposedValidate(_signedOp(PRICE), OP_HASH, 1 ether);
        vm.prank(SENDER);
        token.approve(address(pm), 0); // revoke allowance => transferFrom fails
        pm.exposedPostOp(ctx, GAS, 1 gwei); // must NOT revert (best-effort)
        assertEq(pm.totalFeesCollected(), 0, "nothing charged");
        assertEq(policy.remaining(C), 10 ether - GAS, "budget still consumed (gas was spent)");
    }

    function test_postOp_fee_on_transfer_accounted_by_delta() public {
        // fresh paymaster over a 1%-fee-on-transfer token
        FeeOnTransferToken fot = new FeeOnTransferToken();
        TestableGasXERC20 pm2 = new TestableGasXERC20(
            IEntryPoint(address(ep)), address(policy), "GasX", "1", address(fot), address(oracle), BASE_TOKEN
        );
        pm2.setTrustedSigner(signer, true);
        policy.setStrategy(address(pm2), true);
        bytes32 c2 = keccak256("campaign.fot");
        policy.setCampaign(c2, address(pm2), 10 ether, uint48(block.timestamp + 1 days));
        fot.mint(SENDER, 1_000_000e6);
        vm.prank(SENDER);
        fot.approve(address(pm2), type(uint256).max);

        // context for pm2/c2 (price PRICE => fee PRICE; FOT skims 1% => received 99%)
        bytes memory ctx = abi.encode(c2, SENDER, bytes32("uoh"), PRICE);
        pm2.exposedPostOp(ctx, GAS, 1 gwei);
        assertEq(pm2.totalFeesCollected(), PRICE - (PRICE / 100), "credited the measured balance delta (99%)");
    }

    function testFuzz_feeFor_matches_formula(uint256 gasWei, uint256 price) public view {
        gasWei = bound(gasWei, 0, 1e30);
        price = bound(price, 0, 1e30);
        assertEq(pm.exposedFeeFor(gasWei, price), (gasWei * price) / 1e18);
    }

    function test_withdrawFees_to_recipient() public {
        (bytes memory ctx,) = pm.exposedValidate(_signedOp(PRICE), OP_HASH, 1 ether);
        pm.exposedPostOp(ctx, GAS, 1 gwei); // paymaster now holds PRICE feeToken
        address treasury = address(0x7EA);
        pm.withdrawFees(treasury, 0); // 0 == all
        assertEq(token.balanceOf(treasury), PRICE, "fees withdrawn to recipient");
        assertEq(pm.getFeeBalance(), 0);
    }

    function testFuzz_onlyOwner_admin(address attacker) public {
        vm.assume(attacker != address(this));
        vm.startPrank(attacker);
        vm.expectRevert();
        pm.pause();
        vm.expectRevert();
        pm.withdrawFees(attacker, 0);
        vm.expectRevert();
        pm.setTrustedSigner(attacker, true);
        vm.stopPrank();
    }
}
