// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GasXConfig } from "../src/core/GasXConfig.sol";

/**
 * @title GasXConfig Fuzz Tests
 * @notice Comprehensive fuzz testing for GasXConfig contract
 * @dev Run with: forge test --match-contract GasXConfigFuzzTest -vvv
 */
contract GasXConfigFuzzTest is Test {
    GasXConfig public config;

    address public owner;
    address public oracleSigner;
    address public attacker;

    // Sample function selectors
    bytes4 public constant TRANSFER_SELECTOR = 0xa9059cbb;
    bytes4 public constant APPROVE_SELECTOR = 0x095ea7b3;

    event OracleSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event MaxUsdSet(bytes4 indexed selector, uint256 previousMaxUsd, uint256 newMaxUsd);

    error ZeroAddress();
    error LengthMismatch();

    function setUp() public {
        owner = address(this);
        oracleSigner = vm.addr(1);
        attacker = vm.addr(2);

        config = new GasXConfig(oracleSigner);
    }

    // ─────────────────────────────────────────────────────────
    // DEPLOYMENT FUZZ TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_DeploymentWithValidSigner(address _oracleSigner) public {
        vm.assume(_oracleSigner != address(0));

        GasXConfig newConfig = new GasXConfig(_oracleSigner);
        assertEq(newConfig.oracleSigner(), _oracleSigner);
        assertEq(newConfig.owner(), address(this));
    }

    function testFuzz_DeploymentRevertsWithZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new GasXConfig(address(0));
    }

    // ─────────────────────────────────────────────────────────
    // SET ORACLE SIGNER FUZZ TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_SetOracleSignerValidAddress(address newSigner) public {
        vm.assume(newSigner != address(0));

        address previousSigner = config.oracleSigner();

        vm.expectEmit(true, true, false, false);
        emit OracleSignerUpdated(previousSigner, newSigner);

        config.setOracleSigner(newSigner);
        assertEq(config.oracleSigner(), newSigner);
    }

    function testFuzz_SetOracleSignerRevertsZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        config.setOracleSigner(address(0));
    }

    function testFuzz_SetOracleSignerRevertsNonOwner(address caller) public {
        vm.assume(caller != owner);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert("not owner");
        config.setOracleSigner(vm.addr(100));
    }

    function testFuzz_SetOracleSignerMultipleTimes(address[5] memory signers) public {
        for (uint256 i = 0; i < signers.length; i++) {
            vm.assume(signers[i] != address(0));

            address previousSigner = config.oracleSigner();
            config.setOracleSigner(signers[i]);

            assertEq(config.oracleSigner(), signers[i]);
            assertEq(previousSigner, i == 0 ? oracleSigner : signers[i - 1]);
        }
    }

    // ─────────────────────────────────────────────────────────
    // SET MAX USD FUZZ TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_SetMaxUsdAnySelector(bytes4 selector, uint256 maxUsd) public {
        vm.expectEmit(true, false, false, true);
        emit MaxUsdSet(selector, 0, maxUsd);

        config.setMaxUsd(selector, maxUsd);
        assertEq(config.getMaxUsd(selector), maxUsd);
    }

    function testFuzz_SetMaxUsdUpdateValue(bytes4 selector, uint256 initialValue, uint256 newValue) public {
        config.setMaxUsd(selector, initialValue);
        assertEq(config.getMaxUsd(selector), initialValue);

        vm.expectEmit(true, false, false, true);
        emit MaxUsdSet(selector, initialValue, newValue);

        config.setMaxUsd(selector, newValue);
        assertEq(config.getMaxUsd(selector), newValue);
    }

    function testFuzz_SetMaxUsdRevertsNonOwner(address caller, bytes4 selector, uint256 maxUsd) public {
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert("not owner");
        config.setMaxUsd(selector, maxUsd);
    }

    function testFuzz_SetMaxUsdToZero(bytes4 selector, uint256 initialValue) public {
        config.setMaxUsd(selector, initialValue);
        assertEq(config.getMaxUsd(selector), initialValue);

        config.setMaxUsd(selector, 0);
        assertEq(config.getMaxUsd(selector), 0);
    }

    function testFuzz_SetMaxUsdMaxValue(bytes4 selector) public {
        uint256 maxValue = type(uint256).max;
        config.setMaxUsd(selector, maxValue);
        assertEq(config.getMaxUsd(selector), maxValue);
    }

    // ─────────────────────────────────────────────────────────
    // BULK SET MAX USD FUZZ TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_BulkSetMaxUsd(uint8 count) public {
        // Limit count to reasonable range (0-100)
        count = uint8(bound(count, 0, 100));

        bytes4[] memory selectors = new bytes4[](count);
        uint256[] memory maxUsds = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            selectors[i] = bytes4(keccak256(abi.encodePacked(i)));
            maxUsds[i] = i * 1e6; // Incremental values
        }

        config.bulkSetMaxUsd(selectors, maxUsds);

        for (uint256 i = 0; i < count; i++) {
            assertEq(config.getMaxUsd(selectors[i]), maxUsds[i]);
        }
    }

    function testFuzz_BulkSetMaxUsdLengthMismatch(uint8 selectorCount, uint8 maxUsdCount) public {
        // Limit to reasonable sizes first
        selectorCount = uint8(bound(selectorCount, 0, 50));
        maxUsdCount = uint8(bound(maxUsdCount, 0, 50));

        // Skip when lengths are equal
        vm.assume(selectorCount != maxUsdCount);

        bytes4[] memory selectors = new bytes4[](selectorCount);
        uint256[] memory maxUsds = new uint256[](maxUsdCount);

        for (uint256 i = 0; i < selectorCount; i++) {
            selectors[i] = bytes4(keccak256(abi.encodePacked(i)));
        }

        for (uint256 i = 0; i < maxUsdCount; i++) {
            maxUsds[i] = i * 1e6;
        }

        vm.expectRevert(LengthMismatch.selector);
        config.bulkSetMaxUsd(selectors, maxUsds);
    }

    function testFuzz_BulkSetMaxUsdRevertsNonOwner(address caller) public {
        vm.assume(caller != owner);

        bytes4[] memory selectors = new bytes4[](1);
        uint256[] memory maxUsds = new uint256[](1);
        selectors[0] = TRANSFER_SELECTOR;
        maxUsds[0] = 1e6;

        vm.prank(caller);
        vm.expectRevert("not owner");
        config.bulkSetMaxUsd(selectors, maxUsds);
    }

    function testFuzz_BulkSetMaxUsdEmptyArrays() public {
        bytes4[] memory selectors = new bytes4[](0);
        uint256[] memory maxUsds = new uint256[](0);

        // Should not revert
        config.bulkSetMaxUsd(selectors, maxUsds);
    }

    // ─────────────────────────────────────────────────────────
    // VIEW FUNCTIONS FUZZ TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_GetMaxUsdUnknownSelector(bytes4 selector) public {
        assertEq(config.getMaxUsd(selector), 0);
    }

    function testFuzz_GetAllLimits(uint8 count) public {
        count = uint8(bound(count, 0, 50));

        bytes4[] memory selectors = new bytes4[](count);
        uint256[] memory expectedValues = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            selectors[i] = bytes4(keccak256(abi.encodePacked(i)));
            expectedValues[i] = i * 1e6;
            config.setMaxUsd(selectors[i], expectedValues[i]);
        }

        uint256[] memory results = config.getAllLimits(selectors);
        assertEq(results.length, count);

        for (uint256 i = 0; i < count; i++) {
            assertEq(results[i], expectedValues[i]);
        }
    }

    // ─────────────────────────────────────────────────────────
    // INVARIANT PROPERTIES
    // ─────────────────────────────────────────────────────────

    function testFuzz_OwnerIsImmutable() public {
        // Owner should always be the deployer
        assertEq(config.owner(), owner);
    }

    function testFuzz_OracleSignerNeverZero(address newSigner) public {
        vm.assume(newSigner != address(0));

        // After any valid setOracleSigner call, signer should not be zero
        config.setOracleSigner(newSigner);
        assertTrue(config.oracleSigner() != address(0));
    }

    // ─────────────────────────────────────────────────────────
    // EDGE CASE TESTS
    // ─────────────────────────────────────────────────────────

    function testFuzz_SameValueUpdates(bytes4 selector, uint256 value) public {
        config.setMaxUsd(selector, value);
        assertEq(config.getMaxUsd(selector), value);

        // Setting same value should still work
        config.setMaxUsd(selector, value);
        assertEq(config.getMaxUsd(selector), value);
    }

    function testFuzz_DuplicateSelectorsInBulk(uint256 value1, uint256 value2) public {
        bytes4[] memory selectors = new bytes4[](2);
        uint256[] memory maxUsds = new uint256[](2);

        // Same selector twice - last value should win
        selectors[0] = TRANSFER_SELECTOR;
        selectors[1] = TRANSFER_SELECTOR;
        maxUsds[0] = value1;
        maxUsds[1] = value2;

        config.bulkSetMaxUsd(selectors, maxUsds);

        // Last value should be the one stored
        assertEq(config.getMaxUsd(TRANSFER_SELECTOR), value2);
    }

    function testFuzz_ZeroSelector() public {
        bytes4 zeroSelector = bytes4(0);
        uint256 maxUsd = 100e6;

        config.setMaxUsd(zeroSelector, maxUsd);
        assertEq(config.getMaxUsd(zeroSelector), maxUsd);
    }

    function testFuzz_MaxSelector() public {
        bytes4 maxSelector = bytes4(type(uint32).max);
        uint256 maxUsd = 100e6;

        config.setMaxUsd(maxSelector, maxUsd);
        assertEq(config.getMaxUsd(maxSelector), maxUsd);
    }
}
