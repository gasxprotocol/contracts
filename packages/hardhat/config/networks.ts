// =================================================================================================
// CONFIGURATION
// This section defines the network-specific parameters for GasX contracts.
// =================================================================================================

export interface NetworkConfig {
  // Common configuration
  oracleSigner?: string;
  entryPoint?: string;
  treasury?: string;
  stakeEth?: string;
  depositEth?: string;
  blockExplorerUrl?: string;

  // ERC20 Fee Paymaster configuration
  feeToken?: string; // Address of the ERC20 token for fee payment (e.g., USDC)
  priceQuoteBaseToken?: string; // Address of the base token for price quotes (e.g., WETH)
  minFee?: string; // Minimum fee in fee token units
  feeMarkupBps?: string; // Fee markup in basis points (e.g., "100" = 1%)
}

export const networkConfigs: Record<string, NetworkConfig> = {
  // --- LOCAL / DEVELOPMENT ---
  "31337": {
    // hardhat - uses mock contracts deployed locally
    oracleSigner: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    stakeEth: "0.01",
    depositEth: "0.05",
    // ERC20 paymaster uses mocks on local network (deployed via fixtures)
    // feeToken, priceQuoteBaseToken are set via environment or mocks
  },

  // --- TESTNETS ---
  "11155111": {
    // sepolia
    oracleSigner: process.env.SEPOLIA_ORACLE_SIGNER ?? "",
    treasury: process.env.SEPOLIA_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://sepolia.etherscan.io",
    // ERC20 Paymaster config
    feeToken: process.env.SEPOLIA_FEE_TOKEN ?? "", // USDC on Sepolia
    priceQuoteBaseToken: process.env.SEPOLIA_WETH ?? "", // WETH on Sepolia
    minFee: process.env.SEPOLIA_MIN_FEE ?? "10000", // 0.01 USDC (6 decimals)
    feeMarkupBps: process.env.SEPOLIA_FEE_MARKUP_BPS ?? "100", // 1%
  },

  "421614": {
    // arbitrumSepolia
    oracleSigner: process.env.ARBITRUM_SEPOLIA_ORACLE_SIGNER ?? "",
    treasury: process.env.ARBITRUM_SEPOLIA_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://sepolia.arbiscan.io",
    stakeEth: "0.01",
    depositEth: "0.05",
    // ERC20 Paymaster config
    feeToken: process.env.ARBITRUM_SEPOLIA_FEE_TOKEN ?? "", // USDC on Arbitrum Sepolia
    priceQuoteBaseToken: process.env.ARBITRUM_SEPOLIA_WETH ?? "", // WETH on Arbitrum Sepolia
    minFee: process.env.ARBITRUM_SEPOLIA_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.ARBITRUM_SEPOLIA_FEE_MARKUP_BPS ?? "100",
  },

  "84532": {
    // baseSepolia
    oracleSigner: process.env.BASE_SEPOLIA_ORACLE_SIGNER ?? "",
    treasury: process.env.BASE_SEPOLIA_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://sepolia.basescan.org",
    // ERC20 Paymaster config
    feeToken: process.env.BASE_SEPOLIA_FEE_TOKEN ?? "", // USDC on Base Sepolia
    priceQuoteBaseToken: process.env.BASE_SEPOLIA_WETH ?? "", // WETH on Base Sepolia
    minFee: process.env.BASE_SEPOLIA_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.BASE_SEPOLIA_FEE_MARKUP_BPS ?? "100",
  },

  "534351": {
    // scrollSepolia
    oracleSigner: process.env.SCROLL_SEPOLIA_ORACLE_SIGNER ?? "",
    treasury: process.env.SCROLL_SEPOLIA_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://sepolia.scrollscan.com",
    // ERC20 Paymaster config
    feeToken: process.env.SCROLL_SEPOLIA_FEE_TOKEN ?? "", // USDC on Scroll Sepolia
    priceQuoteBaseToken: process.env.SCROLL_SEPOLIA_WETH ?? "", // WETH on Scroll Sepolia
    minFee: process.env.SCROLL_SEPOLIA_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.SCROLL_SEPOLIA_FEE_MARKUP_BPS ?? "100",
  },

  // --- MAINNETS ---
  "1": {
    // ethereum mainnet
    oracleSigner: process.env.MAINNET_ORACLE_SIGNER ?? "",
    treasury: process.env.MAINNET_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://etherscan.io",
    // ERC20 Paymaster config
    feeToken: process.env.MAINNET_FEE_TOKEN ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC on Mainnet
    priceQuoteBaseToken: process.env.MAINNET_WETH ?? "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // WETH on Mainnet
    minFee: process.env.MAINNET_MIN_FEE ?? "10000", // 0.01 USDC
    feeMarkupBps: process.env.MAINNET_FEE_MARKUP_BPS ?? "100", // 1%
  },

  "42161": {
    // arbitrum one (mainnet)
    oracleSigner: process.env.ARBITRUM_ORACLE_SIGNER ?? "",
    treasury: process.env.ARBITRUM_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://arbiscan.io",
    // ERC20 Paymaster config
    feeToken: process.env.ARBITRUM_FEE_TOKEN ?? "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // USDC on Arbitrum
    priceQuoteBaseToken: process.env.ARBITRUM_WETH ?? "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", // WETH on Arbitrum
    minFee: process.env.ARBITRUM_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.ARBITRUM_FEE_MARKUP_BPS ?? "100",
  },

  "8453": {
    // base mainnet
    oracleSigner: process.env.BASE_ORACLE_SIGNER ?? "",
    treasury: process.env.BASE_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://basescan.org",
    // ERC20 Paymaster config
    feeToken: process.env.BASE_FEE_TOKEN ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // USDC on Base
    priceQuoteBaseToken: process.env.BASE_WETH ?? "0x4200000000000000000000000000000000000006", // WETH on Base
    minFee: process.env.BASE_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.BASE_FEE_MARKUP_BPS ?? "100",
  },

  "534352": {
    // scroll mainnet
    oracleSigner: process.env.SCROLL_ORACLE_SIGNER ?? "",
    treasury: process.env.SCROLL_PAYMASTER_TREASURY ?? "",
    blockExplorerUrl: "https://scrollscan.com",
    // ERC20 Paymaster config
    feeToken: process.env.SCROLL_FEE_TOKEN ?? "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4", // USDC on Scroll
    priceQuoteBaseToken: process.env.SCROLL_WETH ?? "0x5300000000000000000000000000000000000004", // WETH on Scroll
    minFee: process.env.SCROLL_MIN_FEE ?? "10000",
    feeMarkupBps: process.env.SCROLL_FEE_MARKUP_BPS ?? "100",
  },
};
