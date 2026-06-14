// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/oracles/MultiOracleAggregator.sol";
import "../src/mocks/MockOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MultiOracleAggregator Foundry Fuzz Tests
 * @notice Property-based fuzz testing for MultiOracleAggregator
 * @dev Run with: forge test --match-contract MultiOracleAggregatorFuzzTest -vvv
 */
contract MultiOracleAggregatorFuzzTest is Test {
    MultiOracleAggregator public aggregator;
    MockOracle public oracle1;
    MockOracle public oracle2;
    MockOracle public oracle3;

    address public owner = address(this);
    address public constant BASE = address(0x1);
    address public constant QUOTE = address(0x2);

    uint256 public constant INITIAL_DEVIATION_BPS = 500; // 5%
    uint256 public constant PRECISION = 1e18;

    event OracleAdded(address indexed base, address indexed quote, address oracle);
    event OracleRemoved(address indexed base, address indexed quote, address oracle);
    event MaxDeviationUpdated(uint256 oldValue, uint256 newValue);

    function setUp() public {
        // Deploy implementation
        MultiOracleAggregator impl = new MultiOracleAggregator();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(MultiOracleAggregator.initialize, (owner, INITIAL_DEVIATION_BPS));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        aggregator = MultiOracleAggregator(address(proxy));

        // Deploy mock oracles with different prices
        oracle1 = new MockOracle(1e18); // 1.0
        oracle2 = new MockOracle(1.02e18); // 1.02
        oracle3 = new MockOracle(1.05e18); // 1.05
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Max Deviation BPS bounds
    // ─────────────────────────────────────────────────────────

    function testFuzz_SetMaxDeviationBps_BoundedBy10000(uint256 bps) public {
        // DeviationTooHigh error takes a uint256 parameter
        if (bps > 10000) {
            vm.expectRevert(abi.encodeWithSelector(MultiOracleAggregator.DeviationTooHigh.selector, bps));
            aggregator.setMaxDeviationBps(bps);
        } else {
            aggregator.setMaxDeviationBps(bps);
            assertEq(aggregator.maxDeviationBps(), bps);
        }
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Oracle count after add/remove
    // ─────────────────────────────────────────────────────────

    function testFuzz_OracleCount_Invariant(uint8 addCount) public {
        // Limit to reasonable number (1-5 to avoid gas issues)
        uint256 count = bound(addCount, 1, 5);

        MockOracle[] memory oracles = new MockOracle[](count);

        // Add oracles
        for (uint256 i = 0; i < count; i++) {
            oracles[i] = new MockOracle(1e18 + i * 0.01e18);
            aggregator.addOracle(BASE, QUOTE, address(oracles[i]));
        }

        assertEq(aggregator.oracleCount(BASE, QUOTE), count);

        // Remove all oracles
        for (uint256 i = 0; i < count; i++) {
            aggregator.removeOracle(BASE, QUOTE, 0); // Always remove first
        }

        assertEq(aggregator.oracleCount(BASE, QUOTE), 0);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Average calculation correctness
    // ─────────────────────────────────────────────────────────

    function testFuzz_AverageQuote_Correctness(uint128 price1, uint128 price2, uint128 amount) public {
        // Bound prices to reasonable range (avoid zero and overflow)
        // Use tighter bounds to ensure prices are within 10% of each other
        uint256 basePrice = bound(price1, 1e18, 100e18);
        // p2 is within 5% of p1 to stay within 10% deviation
        uint256 p1 = basePrice;
        uint256 p2 = bound(price2, (basePrice * 95) / 100, (basePrice * 105) / 100);
        uint256 amt = bound(amount, 1e15, 100e18); // Min 0.001 to avoid zero results

        // Check deviation is within bounds (10% for this test)
        aggregator.setMaxDeviationBps(1000); // 10%

        // Setup oracles
        MockOracle o1 = new MockOracle(p1);
        MockOracle o2 = new MockOracle(p2);

        aggregator.addOracle(BASE, QUOTE, address(o1));
        aggregator.addOracle(BASE, QUOTE, address(o2));

        // NOTE: Function signature is getQuoteAverage(amount, base, quote)
        uint256 quote = aggregator.getQuoteAverage(amt, BASE, QUOTE);

        // Average should be: (p1 + p2) / 2 * amount / PRECISION
        uint256 expectedAverage = ((p1 + p2) / 2) * amt / PRECISION;

        // Allow for rounding differences - larger tolerance for larger amounts
        // due to integer division rounding at multiple steps
        uint256 tolerance = amt / 1e16 + 10; // Scale tolerance with amount
        assertApproxEqAbs(quote, expectedAverage, tolerance);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Median calculation with 3 oracles
    // ─────────────────────────────────────────────────────────

    function testFuzz_MedianQuote_ThreeOracles(uint128 p1, uint128 p2, uint128 p3, uint128 amount) public {
        // Bound prices to a tighter range to stay within deviation limits
        // All prices within 20% of base to stay within 100% deviation from median
        uint256 basePrice = bound(p1, 1e18, 10e18);
        uint256 price1 = basePrice;
        uint256 price2 = bound(p2, (basePrice * 90) / 100, (basePrice * 110) / 100);
        uint256 price3 = bound(p3, (basePrice * 90) / 100, (basePrice * 110) / 100);
        uint256 amt = bound(amount, 1e15, 100e18);

        // Set high deviation tolerance for this test
        aggregator.setMaxDeviationBps(5000); // 50% (safe for 20% spread)

        MockOracle o1 = new MockOracle(price1);
        MockOracle o2 = new MockOracle(price2);
        MockOracle o3 = new MockOracle(price3);

        aggregator.addOracle(BASE, QUOTE, address(o1));
        aggregator.addOracle(BASE, QUOTE, address(o2));
        aggregator.addOracle(BASE, QUOTE, address(o3));

        // NOTE: Function signature is getQuoteMedian(amount, base, quote)
        uint256 quote = aggregator.getQuoteMedian(amt, BASE, QUOTE);

        // Calculate expected median
        uint256[] memory prices = new uint256[](3);
        prices[0] = price1;
        prices[1] = price2;
        prices[2] = price3;

        // Sort prices
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (prices[j] < prices[i]) {
                    (prices[i], prices[j]) = (prices[j], prices[i]);
                }
            }
        }

        uint256 expectedMedian = prices[1] * amt / PRECISION;

        assertApproxEqAbs(quote, expectedMedian, 2);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Deviation check works correctly
    // ─────────────────────────────────────────────────────────

    function testFuzz_DeviationCheck(uint16 deviationBps, uint128 price1, uint128 price2) public {
        // Bound deviation to valid range
        uint256 maxDev = bound(deviationBps, 100, 5000); // 1%-50%
        uint256 p1 = bound(price1, 1e18, 10e18);
        uint256 p2 = bound(price2, 1e18, 10e18);

        aggregator.setMaxDeviationBps(maxDev);

        MockOracle o1 = new MockOracle(p1);
        MockOracle o2 = new MockOracle(p2);

        aggregator.addOracle(BASE, QUOTE, address(o1));
        aggregator.addOracle(BASE, QUOTE, address(o2));

        // Calculate actual deviation from average (how contract calculates it)
        uint256 avg = (p1 + p2) / 2;
        uint256 diff1 = p1 > avg ? p1 - avg : avg - p1;
        uint256 diff2 = p2 > avg ? p2 - avg : avg - p2;
        uint256 maxDiff = diff1 > diff2 ? diff1 : diff2;
        uint256 actualDeviation = (maxDiff * 10000) / avg;

        if (actualDeviation > maxDev) {
            vm.expectRevert(); // Should revert with DeviationTooHigh
            aggregator.getQuoteAverage(1e18, BASE, QUOTE);
        } else {
            // Should succeed
            uint256 quote = aggregator.getQuoteAverage(1e18, BASE, QUOTE);
            assertGt(quote, 0);
        }
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot add duplicate oracles
    // ─────────────────────────────────────────────────────────

    function testFuzz_NoDuplicateOracles(uint8 seed) public {
        address oracleAddr = address(new MockOracle(1e18));

        aggregator.addOracle(BASE, QUOTE, oracleAddr);

        // Second add should revert
        vm.expectRevert(abi.encodeWithSelector(MultiOracleAggregator.DuplicateOracle.selector));
        aggregator.addOracle(BASE, QUOTE, oracleAddr);

        assertEq(aggregator.oracleCount(BASE, QUOTE), 1);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot add zero address oracle
    // ─────────────────────────────────────────────────────────

    function testFuzz_CannotAddZeroOracle(address base, address quote) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);

        vm.expectRevert(abi.encodeWithSelector(MultiOracleAggregator.ZeroOracle.selector));
        aggregator.addOracle(base, quote, address(0));
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Remove oracle index bounds
    // ─────────────────────────────────────────────────────────

    function testFuzz_RemoveOracleIndexBounds(uint256 index) public {
        // Add one oracle
        aggregator.addOracle(BASE, QUOTE, address(oracle1));

        if (index >= 1) {
            vm.expectRevert(abi.encodeWithSelector(MultiOracleAggregator.InvalidIndex.selector));
            aggregator.removeOracle(BASE, QUOTE, index);
        } else {
            aggregator.removeOracle(BASE, QUOTE, index);
            assertEq(aggregator.oracleCount(BASE, QUOTE), 0);
        }
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Update oracle replaces correctly
    // ─────────────────────────────────────────────────────────

    function testFuzz_UpdateOracle(uint128 oldPrice, uint128 newPrice) public {
        uint256 pOld = bound(oldPrice, 0.1e18, 100e18);
        uint256 pNew = bound(newPrice, 0.1e18, 100e18);

        MockOracle oOld = new MockOracle(pOld);
        MockOracle oNew = new MockOracle(pNew);

        aggregator.addOracle(BASE, QUOTE, address(oOld));

        aggregator.updateOracle(BASE, QUOTE, 0, address(oNew));

        assertEq(aggregator.oracleCount(BASE, QUOTE), 1);

        // Only oracle should be the new one
        aggregator.setMaxDeviationBps(10000); // Allow any deviation for single oracle
        uint256 quote = aggregator.getQuoteAverage(PRECISION, BASE, QUOTE);
        assertEq(quote, pNew);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Toggle oracle enabled/disabled
    // ─────────────────────────────────────────────────────────

    function testFuzz_ToggleOracle(bool initialEnabled) public {
        aggregator.addOracle(BASE, QUOTE, address(oracle1));

        if (!initialEnabled) {
            aggregator.toggleOracle(BASE, QUOTE, 0, false);
        }

        // Toggle once
        aggregator.toggleOracle(BASE, QUOTE, 0, initialEnabled);

        // If initially enabled, now disabled (and vice versa)
        // We can't directly check enabled status, but we can check behavior
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Quote amount scaling
    // ─────────────────────────────────────────────────────────

    function testFuzz_QuoteAmountScaling(uint128 amount) public {
        uint256 amt = bound(amount, 1, type(uint128).max);

        aggregator.addOracle(BASE, QUOTE, address(oracle1)); // Price = 1e18

        uint256 quote = aggregator.getQuoteAverage(amt, BASE, QUOTE);

        // With price = 1e18, quote should equal amount
        assertEq(quote, amt);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Multiple pairs independent
    // ─────────────────────────────────────────────────────────

    function testFuzz_MultiplePairsIndependent(address base2, address quote2) public {
        vm.assume(base2 != address(0) && quote2 != address(0) && base2 != quote2);
        vm.assume(base2 != BASE || quote2 != QUOTE); // Different pair

        MockOracle o1 = new MockOracle(1e18);
        MockOracle o2 = new MockOracle(2e18);

        aggregator.addOracle(BASE, QUOTE, address(o1));
        aggregator.addOracle(base2, quote2, address(o2));

        assertEq(aggregator.oracleCount(BASE, QUOTE), 1);
        assertEq(aggregator.oracleCount(base2, quote2), 1);

        uint256 q1 = aggregator.getQuoteAverage(PRECISION, BASE, QUOTE);
        uint256 q2 = aggregator.getQuoteAverage(PRECISION, base2, quote2);

        assertEq(q1, 1e18);
        assertEq(q2, 2e18);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Owner-only functions access control
    // ─────────────────────────────────────────────────────────

    function testFuzz_OnlyOwnerFunctions(address caller) public {
        vm.assume(caller != owner);

        vm.startPrank(caller);

        vm.expectRevert();
        aggregator.addOracle(BASE, QUOTE, address(oracle1));

        vm.expectRevert();
        aggregator.setMaxDeviationBps(100);

        vm.stopPrank();
    }
}
