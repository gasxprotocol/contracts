// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/GasXSubscriptions.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title GasXSubscriptions Fuzz Tests
 * @notice Foundry fuzz tests for subscription and credit payment functions
 * @dev Run with: forge test --match-contract GasXSubscriptionsFuzz -vvv
 */
contract GasXSubscriptionsFuzzTest is Test {
    GasXSubscriptions public implementation;
    GasXSubscriptions public subscriptions;

    MockERC20 public usdc;
    MockERC20 public usdt;

    address public owner;
    address public treasury;
    address public feeCollector;
    address public user1;

    uint256 constant USDC_DECIMALS = 6;
    uint256 constant PRO_PRICE_USDC = 99_000000; // 99 USDC
    uint256 constant PRO_PRICE_ETH = 0.04 ether;

    function setUp() public {
        owner = address(this);
        treasury = address(0x1111111111111111111111111111111111111111);
        feeCollector = address(0x2222222222222222222222222222222222222222);
        user1 = address(0x3333333333333333333333333333333333333333);

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy implementation
        implementation = new GasXSubscriptions();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(GasXSubscriptions.initialize.selector, treasury, address(usdc));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        subscriptions = GasXSubscriptions(payable(address(proxy)));

        // Setup
        subscriptions.setFeeCollector(feeCollector);
        subscriptions.addSupportedToken(address(usdt), 6);

        // Fund user
        usdc.mint(user1, 1_000_000 * 10 ** USDC_DECIMALS);
        usdt.mint(user1, 1_000_000 * 10 ** USDC_DECIMALS);
        vm.deal(user1, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SUBSCRIPTION FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: Subscribe with random plan IDs
    /// @dev Should only succeed for valid, active plans
    function testFuzz_SubscribeWithPlanId(uint256 planId) public {
        vm.startPrank(user1);

        uint256 planCount = subscriptions.planCount();

        if (planId >= planCount) {
            // Should revert for invalid plan ID
            vm.expectRevert(GasXSubscriptions.InvalidPlan.selector);
            subscriptions.subscribe(planId, address(usdc), false);
        } else {
            // Get plan details
            (, uint256 priceUsdc, , , , bool active) = subscriptions.plans(planId);

            if (!active) {
                vm.expectRevert(GasXSubscriptions.InvalidPlan.selector);
                subscriptions.subscribe(planId, address(usdc), false);
            } else {
                // Approve and subscribe
                usdc.approve(address(subscriptions), priceUsdc);
                subscriptions.subscribe(planId, address(usdc), false);

                // Verify subscription
                (bool isActive, uint256 subPlanId, ) = subscriptions.getSubscriptionStatus(user1);
                assertTrue(isActive || priceUsdc == 0, "Should be active or free plan");
                assertEq(subPlanId, planId, "Plan ID should match");
            }
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: Subscribe with ETH - random amounts
    /// @dev Should handle overpayment refunds correctly
    function testFuzz_SubscribeWithEth_Refund(uint256 ethAmount) public {
        // Bound to reasonable range
        ethAmount = bound(ethAmount, PRO_PRICE_ETH, 10 ether);

        vm.startPrank(user1);

        uint256 balanceBefore = user1.balance;

        subscriptions.subscribeWithEth{ value: ethAmount }(1, false);

        uint256 balanceAfter = user1.balance;
        uint256 spent = balanceBefore - balanceAfter;

        // Should only spend exactly PRO_PRICE_ETH (excess refunded)
        assertEq(spent, PRO_PRICE_ETH, "Should only spend exact price");

        vm.stopPrank();
    }

    /// @notice Fuzz test: Subscribe with insufficient ETH
    /// @dev Should always revert
    function testFuzz_SubscribeWithEth_Insufficient(uint256 ethAmount) public {
        // Bound to less than required
        ethAmount = bound(ethAmount, 0, PRO_PRICE_ETH - 1);

        vm.startPrank(user1);

        vm.expectRevert(GasXSubscriptions.InsufficientPayment.selector);
        subscriptions.subscribeWithEth{ value: ethAmount }(1, false);

        vm.stopPrank();
    }

    /// @notice Fuzz test: Multiple subscriptions should extend end time
    function testFuzz_SubscriptionExtension(uint8 numSubscriptions) public {
        // Bound to reasonable number
        numSubscriptions = uint8(bound(numSubscriptions, 1, 5));

        vm.startPrank(user1);

        uint256 totalPrice = PRO_PRICE_USDC * numSubscriptions;
        usdc.approve(address(subscriptions), totalPrice);

        uint256 lastEndTime = 0;

        for (uint8 i = 0; i < numSubscriptions; i++) {
            subscriptions.subscribe(1, address(usdc), false);

            (, , uint256 endTime) = subscriptions.getSubscriptionStatus(user1);

            // Each subscription should extend the end time
            assertGt(endTime, lastEndTime, "End time should increase");
            lastEndTime = endTime;
        }

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CREDIT PURCHASE FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: Purchase credits with random pack IDs
    function testFuzz_PurchaseCreditsWithPackId(uint256 packId) public {
        vm.startPrank(user1);

        uint256 packCount = subscriptions.creditPackCount();

        if (packId >= packCount) {
            vm.expectRevert(GasXSubscriptions.InvalidCreditPack.selector);
            subscriptions.purchaseCredits(packId, address(usdc));
        } else {
            (, uint256 credits, uint256 bonusCredits, uint256 priceUsdc, , bool active) = subscriptions.creditPacks(
                packId
            );

            if (!active) {
                vm.expectRevert(GasXSubscriptions.InvalidCreditPack.selector);
                subscriptions.purchaseCredits(packId, address(usdc));
            } else {
                usdc.approve(address(subscriptions), priceUsdc);

                uint256 creditsBefore = subscriptions.getCreditBalance(user1);
                subscriptions.purchaseCredits(packId, address(usdc));
                uint256 creditsAfter = subscriptions.getCreditBalance(user1);

                assertEq(creditsAfter - creditsBefore, credits + bonusCredits, "Should receive correct credits");
            }
        }

        vm.stopPrank();
    }

    /// @notice Fuzz test: Credit usage should never exceed balance
    function testFuzz_CreditUsage(uint256 purchaseCount, uint256 useAmount) public {
        // Bound inputs
        purchaseCount = bound(purchaseCount, 1, 10);

        vm.startPrank(user1);

        // Purchase credits
        (, uint256 credits, uint256 bonusCredits, uint256 priceUsdc, , ) = subscriptions.creditPacks(0); // Starter pack

        uint256 totalPrice = priceUsdc * purchaseCount;
        usdc.approve(address(subscriptions), totalPrice);

        for (uint256 i = 0; i < purchaseCount; i++) {
            subscriptions.purchaseCredits(0, address(usdc));
        }

        vm.stopPrank();

        uint256 totalCredits = (credits + bonusCredits) * purchaseCount;
        uint256 balance = subscriptions.getCreditBalance(user1);
        assertEq(balance, totalCredits, "Balance should match purchases");

        // Bound use amount
        useAmount = bound(useAmount, 0, type(uint256).max);

        // Owner tries to use credits
        if (useAmount > balance) {
            vm.expectRevert(GasXSubscriptions.InsufficientCredits.selector);
            subscriptions.useCredits(user1, useAmount, "fuzz test");
        } else {
            subscriptions.useCredits(user1, useAmount, "fuzz test");
            assertEq(subscriptions.getCreditBalance(user1), balance - useAmount, "Balance should decrease");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTION FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: Platform fee should never exceed MAX_PLATFORM_FEE_BPS
    function testFuzz_CreatePlanFeeCap(uint256 feeBps) public {
        uint256 maxFee = subscriptions.MAX_PLATFORM_FEE_BPS();

        if (feeBps > maxFee) {
            vm.expectRevert(GasXSubscriptions.FeeTooHigh.selector);
            subscriptions.createPlan("fuzz", 100_000000, 0.05 ether, 30, feeBps);
        } else {
            uint256 planId = subscriptions.createPlan("fuzz", 100_000000, 0.05 ether, 30, feeBps);

            (, , , , uint256 storedFee, ) = subscriptions.plans(planId);
            assertEq(storedFee, feeBps, "Fee should be stored correctly");
        }
    }

    /// @notice Fuzz test: Only owner can perform admin functions
    function testFuzz_OnlyOwnerCanAdmin(address caller) public {
        vm.assume(caller != address(this)); // Not the owner

        vm.startPrank(caller);

        vm.expectRevert(GasXSubscriptions.Unauthorized.selector);
        subscriptions.createPlan("hack", 1, 1, 1, 100);

        vm.expectRevert(GasXSubscriptions.Unauthorized.selector);
        subscriptions.setTreasury(caller);

        vm.expectRevert(GasXSubscriptions.Unauthorized.selector);
        subscriptions.pause();

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE CONVERSION FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test: Token decimal conversion
    /// @dev Tests that low-decimal tokens with small prices correctly revert with AmountTooSmall
    function testFuzz_TokenDecimalConversion(uint8 decimals, uint256 priceUsdc) public {
        // Bound decimals to reasonable range
        decimals = uint8(bound(decimals, 2, 18));
        // Bound price to avoid overflow
        priceUsdc = bound(priceUsdc, 1, 1_000_000_000_000); // Max 1M USDC

        // Deploy new token with fuzzed decimals
        MockERC20 fuzzToken = new MockERC20("Fuzz Token", "FUZZ", decimals);
        subscriptions.addSupportedToken(address(fuzzToken), decimals);

        // Create a plan with the price
        uint256 planId = subscriptions.createPlan(
            "fuzzPlan",
            priceUsdc,
            0, // No ETH price
            30,
            100
        );

        // Mint tokens to user (enough for any conversion)
        uint256 maxAmount = priceUsdc * (10 ** 18); // Way more than needed
        fuzzToken.mint(user1, maxAmount);

        vm.startPrank(user1);
        fuzzToken.approve(address(subscriptions), maxAmount);

        // Calculate if conversion would result in zero (precision loss)
        bool wouldBeZero = false;
        if (decimals < 6) {
            uint256 divisor = 10 ** (6 - decimals);
            wouldBeZero = priceUsdc < divisor;
        }

        if (wouldBeZero) {
            // Should revert with AmountTooSmall for precision loss cases
            vm.expectRevert(GasXSubscriptions.AmountTooSmall.selector);
            subscriptions.subscribe(planId, address(fuzzToken), false);
        } else {
            // The subscription should work
            subscriptions.subscribe(planId, address(fuzzToken), false);

            (bool isActive, , ) = subscriptions.getSubscriptionStatus(user1);
            assertTrue(isActive, "Should be subscribed");
        }

        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MOCK CONTRACTS FOR TESTING
// ═══════════════════════════════════════════════════════════════════════════

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
