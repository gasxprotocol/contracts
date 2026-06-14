// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title GasXSubscriptions
 * @author edsphinx
 * @notice Manages subscription payments and credit purchases for GasX platform
 * @dev Accepts USDC, USDT, DAI, and ETH payments for subscriptions and credits
 *      Uses UUPS proxy pattern for upgradeability
 *
 * Production Security Features:
 * - UUPS upgradeable proxy pattern
 * - Pausable for emergency stops
 * - 2-step ownership transfer (pending owner must accept)
 * - Max platform fee cap (10%)
 * - Emergency token/ETH withdrawal
 * - ReentrancyGuard on all payment functions
 * - SafeERC20 for token transfers
 *
 * Business Features:
 * - Subscription payments (monthly/yearly)
 * - Credit package purchases
 * - Auto-renewal via token approvals
 * - Multi-token support (USDC preferred)
 * - Tiered platform fee collection
 */
contract GasXSubscriptions is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────
    // ░░  CONSTANTS
    // ────────────────────────────────────────────────

    /// @notice Maximum allowed platform fee (10%)
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1000;

    /// @notice Contract version for upgrades
    string public constant VERSION = "1.0.0";

    /// @notice Upgrade timelock delay (48 hours)
    uint256 public constant UPGRADE_TIMELOCK = 48 hours;

    // ────────────────────────────────────────────────
    // ░░  STRUCTS
    // ────────────────────────────────────────────────

    struct Plan {
        string name; // "free", "pro", "enterprise"
        uint256 priceUsdc; // Price in USDC (6 decimals)
        uint256 priceEth; // Alternative price in ETH (wei)
        uint256 durationDays; // Subscription duration (30 for monthly, 365 for yearly)
        uint256 platformFeeBps; // Platform fee in basis points (500 = 5%)
        bool active;
    }

    struct CreditPack {
        string name;
        uint256 credits; // Number of credits
        uint256 bonusCredits; // Bonus credits included
        uint256 priceUsdc; // Price in USDC (6 decimals)
        uint256 priceEth; // Alternative price in ETH (wei)
        bool active;
    }

    struct Subscription {
        uint256 planId;
        uint256 startTime;
        uint256 endTime;
        address paymentToken; // Token used for payment (address(0) for ETH)
        bool autoRenew;
    }

    // ────────────────────────────────────────────────
    // ░░  STATE VARIABLES
    // ────────────────────────────────────────────────

    /// @notice Contract owner
    address public owner;

    /// @notice Pending owner for 2-step transfer
    address public pendingOwner;

    /// @notice Treasury address for collecting payments
    address public treasury;

    /// @notice Supported payment tokens (USDC, USDT, DAI)
    mapping(address => bool) public supportedTokens;

    /// @notice Token decimals for price conversion
    mapping(address => uint8) public tokenDecimals;

    /// @notice Subscription plans
    mapping(uint256 => Plan) public plans;
    uint256 public planCount;

    /// @notice Credit packages
    mapping(uint256 => CreditPack) public creditPacks;
    uint256 public creditPackCount;

    /// @notice User subscriptions (user address => subscription)
    mapping(address => Subscription) public subscriptions;

    /// @notice User credit balances
    mapping(address => uint256) public creditBalances;

    /// @notice Total credits purchased by user
    mapping(address => uint256) public totalCreditsPurchased;

    /// @notice Total credits used by user
    mapping(address => uint256) public totalCreditsUsed;

    /// @notice Platform fee collector (can be different from treasury)
    address public feeCollector;

    /// @notice Accumulated fees per token
    mapping(address => uint256) public accumulatedFees;

    /// @notice Pending upgrade implementation address
    address public pendingUpgrade;

    /// @notice Timestamp when upgrade can be executed
    uint256 public upgradeReadyTime;

    // ────────────────────────────────────────────────
    // ░░  EVENTS
    // ────────────────────────────────────────────────

    event PlanCreated(uint256 indexed planId, string name, uint256 priceUsdc);
    event PlanUpdated(uint256 indexed planId);
    event CreditPackCreated(uint256 indexed packId, string name, uint256 credits, uint256 priceUsdc);

    event SubscriptionPurchased(
        address indexed user,
        uint256 indexed planId,
        address paymentToken,
        uint256 amount,
        uint256 startTime,
        uint256 endTime
    );

    event SubscriptionRenewed(address indexed user, uint256 indexed planId, uint256 newEndTime);

    event SubscriptionCanceled(address indexed user);

    event CreditsPurchased(
        address indexed user,
        uint256 indexed packId,
        uint256 credits,
        address paymentToken,
        uint256 amount
    );

    event CreditsUsed(address indexed user, uint256 amount, string reason);
    event CreditsRefunded(address indexed user, uint256 amount);

    event TokenAdded(address indexed token, uint8 decimals);
    event TokenRemoved(address indexed token);

    event FeesCollected(address indexed token, uint256 amount);
    event TreasuryUpdated(address newTreasury);
    event FeeCollectorUpdated(address newFeeCollector);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event UpgradeScheduled(address indexed newImplementation, uint256 readyTime);
    event UpgradeCanceled(address indexed canceledImplementation);
    event UpgradeExecuted(address indexed newImplementation);
    event OwnershipTransferCanceled(address indexed previousPendingOwner);

    // ────────────────────────────────────────────────
    // ░░  ERRORS
    // ────────────────────────────────────────────────

    error Unauthorized();
    error InvalidPlan();
    error InvalidCreditPack();
    error UnsupportedToken();
    error InsufficientPayment();
    error InsufficientCredits();
    error SubscriptionNotExpired();
    error NoActiveSubscription();
    error TransferFailed();
    error ZeroAddress();
    error FeeTooHigh();
    error NoPendingOwner();
    error UpgradeNotReady();
    error NoUpgradePending();
    error InvalidUpgrade();
    error AmountTooSmall();

    // ────────────────────────────────────────────────
    // ░░  MODIFIERS
    // ────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ────────────────────────────────────────────────
    // ░░  CONSTRUCTOR & INITIALIZER
    // ────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the subscriptions contract (called once via proxy)
     * @param _treasury Address to receive subscription payments
     * @param _usdc USDC token address on this chain
     */
    function initialize(address _treasury, address _usdc) external initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();

        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        owner = msg.sender;
        treasury = _treasury;
        feeCollector = _treasury;

        // Add USDC as default supported token
        supportedTokens[_usdc] = true;
        tokenDecimals[_usdc] = 6;
        emit TokenAdded(_usdc, 6);

        // Create default plans
        _createDefaultPlans();
        _createDefaultCreditPacks();
    }

    /**
     * @notice Authorize upgrade (UUPS pattern) - enforces timelock
     * @dev Upgrade must be scheduled and timelock must have passed
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (pendingUpgrade != newImplementation) revert InvalidUpgrade();
        if (block.timestamp < upgradeReadyTime) revert UpgradeNotReady();

        // Clear pending upgrade
        pendingUpgrade = address(0);
        upgradeReadyTime = 0;

        emit UpgradeExecuted(newImplementation);
    }

    /**
     * @notice Schedule an upgrade (starts 48h timelock)
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();

        pendingUpgrade = newImplementation;
        upgradeReadyTime = block.timestamp + UPGRADE_TIMELOCK;

        emit UpgradeScheduled(newImplementation, upgradeReadyTime);
    }

    /**
     * @notice Cancel a scheduled upgrade
     */
    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade == address(0)) revert NoUpgradePending();

        address canceled = pendingUpgrade;
        pendingUpgrade = address(0);
        upgradeReadyTime = 0;

        emit UpgradeCanceled(canceled);
    }

    // ────────────────────────────────────────────────
    // ░░  SUBSCRIPTION FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Purchase or renew a subscription with ERC20 token
     * @param planId ID of the plan to purchase
     * @param token ERC20 token to pay with (must be supported)
     * @param autoRenew Whether to enable auto-renewal
     */
    function subscribe(uint256 planId, address token, bool autoRenew) external nonReentrant whenNotPaused {
        if (planId >= planCount) revert InvalidPlan();
        Plan storage plan = plans[planId];
        if (!plan.active) revert InvalidPlan();
        if (!supportedTokens[token]) revert UnsupportedToken();

        // Calculate price in the payment token
        uint256 price = _convertPrice(plan.priceUsdc, token);

        // Calculate platform fee
        uint256 fee = (price * plan.platformFeeBps) / 10000;
        uint256 netAmount = price - fee;

        // Transfer tokens
        IERC20(token).safeTransferFrom(msg.sender, treasury, netAmount);
        if (fee > 0) {
            IERC20(token).safeTransferFrom(msg.sender, feeCollector, fee);
            accumulatedFees[token] += fee;
        }

        // Update subscription
        Subscription storage sub = subscriptions[msg.sender];
        uint256 startTime = block.timestamp;

        // If extending existing subscription, start from current end time
        if (sub.endTime > block.timestamp) {
            startTime = sub.endTime;
        }

        uint256 endTime = startTime + (plan.durationDays * 1 days);

        sub.planId = planId;
        sub.startTime = startTime;
        sub.endTime = endTime;
        sub.paymentToken = token;
        sub.autoRenew = autoRenew;

        emit SubscriptionPurchased(msg.sender, planId, token, price, startTime, endTime);
    }

    /**
     * @notice Purchase or renew a subscription with ETH
     * @param planId ID of the plan to purchase
     * @param autoRenew Whether to enable auto-renewal
     */
    function subscribeWithEth(uint256 planId, bool autoRenew) external payable nonReentrant whenNotPaused {
        // ─── CHECKS ─────────────────────────────────────
        if (planId >= planCount) revert InvalidPlan();
        Plan storage plan = plans[planId];
        if (!plan.active) revert InvalidPlan();
        if (plan.priceEth == 0) revert UnsupportedToken();
        if (msg.value < plan.priceEth) revert InsufficientPayment();
        // Defensive check: treasury is validated in setTreasury, but check here too
        if (treasury == address(0)) revert ZeroAddress();

        // Calculate platform fee
        uint256 fee = (plan.priceEth * plan.platformFeeBps) / 10000;
        uint256 netAmount = plan.priceEth - fee;

        // ─── EFFECTS ────────────────────────────────────
        // Update subscription state BEFORE external calls (CEI pattern)
        Subscription storage sub = subscriptions[msg.sender];
        uint256 startTime = block.timestamp;

        if (sub.endTime > block.timestamp) {
            startTime = sub.endTime;
        }

        uint256 endTime = startTime + (plan.durationDays * 1 days);

        sub.planId = planId;
        sub.startTime = startTime;
        sub.endTime = endTime;
        sub.paymentToken = address(0);
        sub.autoRenew = autoRenew;

        if (fee > 0) {
            accumulatedFees[address(0)] += fee;
        }

        emit SubscriptionPurchased(msg.sender, planId, address(0), plan.priceEth, startTime, endTime);

        // ─── INTERACTIONS ───────────────────────────────
        // External calls AFTER state changes
        (bool success, ) = treasury.call{ value: netAmount }("");
        if (!success) revert TransferFailed();

        if (fee > 0) {
            (success, ) = feeCollector.call{ value: fee }("");
            if (!success) revert TransferFailed();
        }

        // Refund excess ETH
        if (msg.value > plan.priceEth) {
            (success, ) = msg.sender.call{ value: msg.value - plan.priceEth }("");
            if (!success) revert TransferFailed();
        }
    }

    /**
     * @notice Cancel auto-renewal for a subscription
     */
    function cancelAutoRenew() external {
        Subscription storage sub = subscriptions[msg.sender];
        if (sub.endTime == 0) revert NoActiveSubscription();

        sub.autoRenew = false;
        emit SubscriptionCanceled(msg.sender);
    }

    /**
     * @notice Renew an expired subscription (keeper or user callable)
     * @param user Address of the user to renew
     */
    function renewSubscription(address user) external nonReentrant whenNotPaused {
        Subscription storage sub = subscriptions[user];
        if (sub.endTime == 0) revert NoActiveSubscription();
        if (!sub.autoRenew) revert NoActiveSubscription();
        if (sub.endTime > block.timestamp) revert SubscriptionNotExpired();

        Plan storage plan = plans[sub.planId];
        if (!plan.active) revert InvalidPlan();

        address token = sub.paymentToken;

        if (token == address(0)) {
            // ETH payment - cannot auto-renew, user must call manually
            revert UnsupportedToken();
        }

        // Calculate price
        uint256 price = _convertPrice(plan.priceUsdc, token);
        uint256 fee = (price * plan.platformFeeBps) / 10000;
        uint256 netAmount = price - fee;

        // Transfer tokens (requires prior approval)
        IERC20(token).safeTransferFrom(user, treasury, netAmount);
        if (fee > 0) {
            IERC20(token).safeTransferFrom(user, feeCollector, fee);
            accumulatedFees[token] += fee;
        }

        // Extend subscription
        uint256 newEndTime = sub.endTime + (plan.durationDays * 1 days);
        sub.endTime = newEndTime;

        emit SubscriptionRenewed(user, sub.planId, newEndTime);
    }

    // ────────────────────────────────────────────────
    // ░░  CREDIT FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Purchase credits with ERC20 token
     * @param packId ID of the credit package
     * @param token ERC20 token to pay with
     */
    function purchaseCredits(uint256 packId, address token) external nonReentrant whenNotPaused {
        if (packId >= creditPackCount) revert InvalidCreditPack();
        CreditPack storage pack = creditPacks[packId];
        if (!pack.active) revert InvalidCreditPack();
        if (!supportedTokens[token]) revert UnsupportedToken();

        uint256 price = _convertPrice(pack.priceUsdc, token);

        // Transfer tokens to treasury
        IERC20(token).safeTransferFrom(msg.sender, treasury, price);

        // Add credits to user balance
        uint256 totalCredits = pack.credits + pack.bonusCredits;
        creditBalances[msg.sender] += totalCredits;
        totalCreditsPurchased[msg.sender] += totalCredits;

        emit CreditsPurchased(msg.sender, packId, totalCredits, token, price);
    }

    /**
     * @notice Purchase credits with ETH
     * @param packId ID of the credit package
     */
    function purchaseCreditsWithEth(uint256 packId) external payable nonReentrant whenNotPaused {
        // ─── CHECKS ─────────────────────────────────────
        if (packId >= creditPackCount) revert InvalidCreditPack();
        CreditPack storage pack = creditPacks[packId];
        if (!pack.active) revert InvalidCreditPack();
        if (pack.priceEth == 0) revert UnsupportedToken();
        if (msg.value < pack.priceEth) revert InsufficientPayment();
        // Defensive check: treasury is validated in setTreasury, but check here too
        if (treasury == address(0)) revert ZeroAddress();

        // ─── EFFECTS ────────────────────────────────────
        // Update state BEFORE external calls (CEI pattern)
        uint256 totalCredits = pack.credits + pack.bonusCredits;
        creditBalances[msg.sender] += totalCredits;
        totalCreditsPurchased[msg.sender] += totalCredits;

        emit CreditsPurchased(msg.sender, packId, totalCredits, address(0), pack.priceEth);

        // ─── INTERACTIONS ───────────────────────────────
        // External calls AFTER state changes
        (bool success, ) = treasury.call{ value: pack.priceEth }("");
        if (!success) revert TransferFailed();

        // Refund excess
        if (msg.value > pack.priceEth) {
            (success, ) = msg.sender.call{ value: msg.value - pack.priceEth }("");
            if (!success) revert TransferFailed();
        }
    }

    /**
     * @notice Use credits (called by authorized platform contracts)
     * @param user Address of the user
     * @param amount Number of credits to use
     * @param reason Description of credit usage
     */
    function useCredits(address user, uint256 amount, string calldata reason) external onlyOwner {
        if (creditBalances[user] < amount) revert InsufficientCredits();

        creditBalances[user] -= amount;
        totalCreditsUsed[user] += amount;

        emit CreditsUsed(user, amount, reason);
    }

    /**
     * @notice Refund credits (admin function)
     * @param user Address of the user
     * @param amount Number of credits to refund
     */
    function refundCredits(address user, uint256 amount) external onlyOwner {
        creditBalances[user] += amount;
        emit CreditsRefunded(user, amount);
    }

    // ────────────────────────────────────────────────
    // ░░  VIEW FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Check if a user has an active subscription
     * @param user Address to check
     * @return isActive True if subscription is active
     * @return planId Current plan ID (0 if none)
     * @return endTime Subscription end timestamp
     */
    function getSubscriptionStatus(
        address user
    ) external view returns (bool isActive, uint256 planId, uint256 endTime) {
        Subscription storage sub = subscriptions[user];
        isActive = sub.endTime > block.timestamp;
        planId = sub.planId;
        endTime = sub.endTime;
    }

    /**
     * @notice Get user's credit balance
     * @param user Address to check
     * @return balance Current credit balance
     */
    function getCreditBalance(address user) external view returns (uint256 balance) {
        return creditBalances[user];
    }

    /**
     * @notice Get plan details
     * @param planId Plan ID to query
     * @return plan Plan struct
     */
    function getPlan(uint256 planId) external view returns (Plan memory) {
        return plans[planId];
    }

    /**
     * @notice Get credit pack details
     * @param packId Pack ID to query
     * @return pack CreditPack struct
     */
    function getCreditPack(uint256 packId) external view returns (CreditPack memory) {
        return creditPacks[packId];
    }

    // ────────────────────────────────────────────────
    // ░░  ADMIN FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Create a new subscription plan
     */
    function createPlan(
        string calldata name,
        uint256 priceUsdc,
        uint256 priceEth,
        uint256 durationDays,
        uint256 platformFeeBps
    ) external onlyOwner returns (uint256 planId) {
        if (platformFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();

        planId = planCount++;
        plans[planId] = Plan({
            name: name,
            priceUsdc: priceUsdc,
            priceEth: priceEth,
            durationDays: durationDays,
            platformFeeBps: platformFeeBps,
            active: true
        });
        emit PlanCreated(planId, name, priceUsdc);
    }

    /**
     * @notice Update an existing plan
     */
    function updatePlan(
        uint256 planId,
        uint256 priceUsdc,
        uint256 priceEth,
        uint256 platformFeeBps,
        bool active
    ) external onlyOwner {
        if (platformFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();

        Plan storage plan = plans[planId];
        plan.priceUsdc = priceUsdc;
        plan.priceEth = priceEth;
        plan.platformFeeBps = platformFeeBps;
        plan.active = active;
        emit PlanUpdated(planId);
    }

    /**
     * @notice Create a new credit package
     */
    function createCreditPack(
        string calldata name,
        uint256 credits,
        uint256 bonusCredits,
        uint256 priceUsdc,
        uint256 priceEth
    ) external onlyOwner returns (uint256 packId) {
        packId = creditPackCount++;
        creditPacks[packId] = CreditPack({
            name: name,
            credits: credits,
            bonusCredits: bonusCredits,
            priceUsdc: priceUsdc,
            priceEth: priceEth,
            active: true
        });
        emit CreditPackCreated(packId, name, credits, priceUsdc);
    }

    /**
     * @notice Add a supported payment token
     */
    function addSupportedToken(address token, uint8 decimals) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        supportedTokens[token] = true;
        tokenDecimals[token] = decimals;
        emit TokenAdded(token, decimals);
    }

    /**
     * @notice Remove a supported payment token
     */
    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    /**
     * @notice Update treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Update fee collector address
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroAddress();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    /**
     * @notice Start 2-step ownership transfer
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /**
     * @notice Accept ownership transfer (must be called by pending owner)
     */
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        if (pendingOwner == address(0)) revert NoPendingOwner();

        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /**
     * @notice Cancel pending ownership transfer
     */
    function cancelOwnershipTransfer() external onlyOwner {
        address canceled = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferCanceled(canceled);
    }

    // ────────────────────────────────────────────────
    // ░░  EMERGENCY FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Pause all payment functions (emergency only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause payment functions
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdraw ERC20 tokens (in case of stuck funds)
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    /**
     * @notice Emergency withdraw ETH (in case of stuck funds)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawEth(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success, ) = to.call{ value: amount }("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdraw(address(0), to, amount);
    }

    // ────────────────────────────────────────────────
    // ░░  INTERNAL FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @dev Convert USDC price to another token's price based on decimals
     * @param usdcAmount Amount in USDC (6 decimals)
     * @param token Target token address
     * @return result Amount in target token
     * @notice Reverts if conversion results in 0 for non-zero input (precision loss protection)
     */
    function _convertPrice(uint256 usdcAmount, address token) internal view returns (uint256 result) {
        // Free plans have 0 price, allow them
        if (usdcAmount == 0) {
            return 0;
        }

        uint8 decimals = tokenDecimals[token];
        if (decimals == 6) {
            result = usdcAmount; // Same decimals as USDC
        } else if (decimals > 6) {
            result = usdcAmount * (10 ** (decimals - 6));
        } else {
            result = usdcAmount / (10 ** (6 - decimals));
        }

        // Protect against precision loss for non-free plans
        if (result == 0) revert AmountTooSmall();
    }

    /**
     * @dev Create default subscription plans
     */
    function _createDefaultPlans() internal {
        // Plan 0: Free (no payment, 30 days, 5% fee)
        plans[planCount++] = Plan({
            name: "free",
            priceUsdc: 0,
            priceEth: 0,
            durationDays: 30,
            platformFeeBps: 500, // 5%
            active: true
        });

        // Plan 1: Pro ($99/month, 2.5% fee)
        plans[planCount++] = Plan({
            name: "pro",
            priceUsdc: 99_000000, // 99 USDC
            priceEth: 40000000000000000, // 0.04 ETH
            durationDays: 30,
            platformFeeBps: 250, // 2.5%
            active: true
        });

        // Plan 2: Enterprise ($499/month, 1% fee)
        plans[planCount++] = Plan({
            name: "enterprise",
            priceUsdc: 499_000000, // 499 USDC
            priceEth: 200000000000000000, // 0.2 ETH
            durationDays: 30,
            platformFeeBps: 100, // 1%
            active: true
        });

        // Plan 3: Pro Yearly ($999/year, 2.5% fee)
        plans[planCount++] = Plan({
            name: "pro_yearly",
            priceUsdc: 999_000000, // 999 USDC
            priceEth: 400000000000000000, // 0.4 ETH
            durationDays: 365,
            platformFeeBps: 250,
            active: true
        });

        // Plan 4: Enterprise Yearly ($4990/year, 1% fee)
        plans[planCount++] = Plan({
            name: "enterprise_yearly",
            priceUsdc: 4990_000000, // 4990 USDC
            priceEth: 2000000000000000000, // 2 ETH
            durationDays: 365,
            platformFeeBps: 100,
            active: true
        });
    }

    /**
     * @dev Create default credit packages
     */
    function _createDefaultCreditPacks() internal {
        // Pack 0: Starter (100 credits, $10)
        creditPacks[creditPackCount++] = CreditPack({
            name: "Starter Pack",
            credits: 100,
            bonusCredits: 0,
            priceUsdc: 10_000000, // 10 USDC
            priceEth: 4000000000000000, // 0.004 ETH
            active: true
        });

        // Pack 1: Growth (500 + 50 bonus credits, $45)
        creditPacks[creditPackCount++] = CreditPack({
            name: "Growth Pack",
            credits: 500,
            bonusCredits: 50,
            priceUsdc: 45_000000, // 45 USDC
            priceEth: 18000000000000000, // 0.018 ETH
            active: true
        });

        // Pack 2: Scale (1000 + 200 bonus credits, $80)
        creditPacks[creditPackCount++] = CreditPack({
            name: "Scale Pack",
            credits: 1000,
            bonusCredits: 200,
            priceUsdc: 80_000000, // 80 USDC
            priceEth: 32000000000000000, // 0.032 ETH
            active: true
        });

        // Pack 3: Enterprise (5000 + 1500 bonus credits, $350)
        creditPacks[creditPackCount++] = CreditPack({
            name: "Enterprise Pack",
            credits: 5000,
            bonusCredits: 1500,
            priceUsdc: 350_000000, // 350 USDC
            priceEth: 140000000000000000, // 0.14 ETH
            active: true
        });
    }

    // ────────────────────────────────────────────────
    // ░░  RECEIVE
    // ────────────────────────────────────────────────

    /**
     * @notice Allow contract to receive ETH
     * @dev Intentionally accepts ETH without restrictions for:
     *      - Receiving ETH payments
     *      - Receiving refunds from failed transactions
     *      Any accidentally sent ETH can be recovered via emergencyWithdrawEth()
     */
    receive() external payable {}
}
