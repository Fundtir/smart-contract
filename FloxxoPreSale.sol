// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FloxxoPreSale
 * @dev A presale contract for Floxxo tokens that allows users to purchase FLOXXO tokens using USDT or USDC
 * 
 * Key Features:
 * - Purchase FLOXXO tokens using USDT or USDC
 * - Configurable token price and minimum purchase threshold
 * - Pausable functionality for emergency stops
 * - Reentrancy protection for secure token transfers
 * - Treasury wallet management for USDT and USDC collection
 * - Admin functions for price and threshold updates
 * 
 * @author Floxxo Team
 */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract FloxxoPreSale is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Mapping to track total tokens bought by each address
    mapping(address => uint256) public tokensBought;

    /// @dev Address of the treasury wallet that receives USDT/USDC payments
    address public treasuryWallet;
    
    /// @dev The Floxxo token contract (FLOXXO)
    IERC20 immutable floxxo;
    
    /// @dev The USDT token contract for payments
    IERC20 immutable usdtToken;
    
    /// @dev The USDC token contract for payments
    IERC20 immutable usdcToken;
    
    /// @dev Token price in USDT (with 18 decimals format)
    uint256 public tokenPrice;
    
    /// @dev Minimum purchase amount in USDT (with 6 decimals for USDT and USDC)
    uint256 public minThresholdLimit;

    /// @dev Emitted when a user purchases tokens
    event TokensPurchased(address indexed buyer, uint256 amount, address indexed token);

    /// @dev Emitted when the minimum threshold is updated
    event MinThresholdUpdated(uint256 indexed newMinThresholdLimit);
    
    /// @dev Emitted when the token price is updated
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);
    
    /// @dev Emitted when admin withdraws tokens from the contract
    event TokensWithdrawn(address indexed admin, uint256 amount);
    
    /// @dev Emitted when the treasury wallet is updated
    event TreasuryWalletUpdated(address indexed newWallet);

    /**
     * @dev Constructor initializes the presale contract with token addresses and pricing
     * @param _tokenPrice Token price in USDT (must be in 18 decimals format)
     * @param _treasuryWallet Address that will receive USDT/USDC payments and become the owner
     * @param _minThresholdLimit Minimum purchase amount in USDT (with 6 decimals for USDT and USDC)
     * @param _Floxxoen Address of the Floxxo token contract
     * @param _usdttoken Address of the USDT token contract
     * @param _usdcToken Address of the USDC token contract
     * 
     * Requirements:
     * - All addresses must be valid (non-zero)
     * - Token price must be greater than 0
     * - Minimum threshold must be greater than 0
     */
    constructor(
        uint256 _tokenPrice,
        address _treasuryWallet,
        uint256 _minThresholdLimit,
        address _Floxxoen,
        address _usdttoken,
        address _usdcToken
    ) Ownable(_treasuryWallet) {
        require(_treasuryWallet != address(0), "Invalid Treasury Wallet");
        require(_Floxxoen != address(0), "Invalid Floxxo Token");
        require(_usdttoken != address(0), "Invalid USDT Token");
        require(_usdcToken != address(0), "Invalid USDC Token");
        require(_tokenPrice > 0, "Price must be greater than 0");
        require(_minThresholdLimit > 0, "Threshold must be greater than 0");

        floxxo = IERC20(_Floxxoen);
        usdtToken = IERC20(_usdttoken);
        usdcToken = IERC20(_usdcToken);
        tokenPrice = _tokenPrice;
        treasuryWallet = _treasuryWallet;
        minThresholdLimit = _minThresholdLimit;
    }

    // ============ ADMIN FUNCTIONS ============
    
    /**
     * @dev Updates the treasury wallet address that receives USDT/USDC payments
     * @param _treasuryWallet New treasury wallet address
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - New treasury wallet must be a valid address (non-zero)
     * - New treasury wallet must be different from current one
     */
    function updateTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != address(0), "Invalid Treasury Wallet");
        require(treasuryWallet != _treasuryWallet, "Use Diff. Wallet");
        treasuryWallet = _treasuryWallet;
        emit TreasuryWalletUpdated(_treasuryWallet);
    }

    // ============ VIEW FUNCTIONS ============
    
    /**
     * @dev Preview how many FLOXXO tokens a user would receive for a given USDT or USDC amount
     * @param amount Amount of USDT/USDC to spend (with 6 decimals for USDT/USDC)
     * @return Amount of FLOXXO tokens that would be received (with 18 decimals)
     */
    function previewFloxxoForStablecoin(
        uint256 amount
    ) external view returns (uint256) {
        return (amount * 1e18 * 1e12) / tokenPrice;
    }

    // ============ PURCHASE FUNCTIONS ============
    
    /**
     * @dev Allows users to purchase FLOXXO tokens using either USDT or USDC
     * @param amount Amount of USDT/USDC to spend (with 6 decimals)
     * @param token Address of the token to use for the purchase (USDT or USDC)
     * 
     * Requirements:
     * - Contract must not be paused
     * - Amount must be greater than 0
     * - Amount must meet minimum threshold requirement
     * - Contract must have sufficient FLOXXO tokens
     * - User must have sufficient balance and allowance of the chosen token
     */
    function buyTokens(uint256 amount, address token) external whenNotPaused nonReentrant {
        require(amount > 0, "Must send some stablecoin");
        require(amount >= minThresholdLimit, "Less Than Threshold");

        // Calculate the number of FLOXXO tokens to be bought
        uint256 FloxxoAmount = (amount * 1e18 * 1e12) / tokenPrice; // Adjust for 18 decimals
        require(FloxxoAmount > 0, "FLOXXO too Small");

        // Check if there are enough tokens in the contract
        require(floxxo.balanceOf(address(this)) >= FloxxoAmount, "Insufficient Floxxo bal");

        // Determine which stablecoin is being used for the purchase
        if (token == address(usdtToken)) {
            // Transfer USDT to the treasury wallet
            usdtToken.safeTransferFrom(msg.sender, treasuryWallet, amount);
        } else if (token == address(usdcToken)) {
            // Transfer USDC to the treasury wallet
            usdcToken.safeTransferFrom(msg.sender, treasuryWallet, amount);
        } else {
            revert("Invalid token address");
        }

        // Transfer FLOXXO tokens to the buyer
        floxxo.safeTransfer(msg.sender, FloxxoAmount);

        // Update user's total tokens bought
        tokensBought[msg.sender] += FloxxoAmount;

        emit TokensPurchased(msg.sender, FloxxoAmount, token);
    }

    /**
     * @dev Updates the token price for FLOXXO tokens
     * @param newTokenPrice New token price in USDT (must be in 18 decimals format)
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - New price must be greater than 0
     */
    function setTokenPrice(uint256 newTokenPrice) external onlyOwner {
        require(newTokenPrice > 0, "Price must be greater than 0");
        uint256 oldPrice = tokenPrice;
        tokenPrice = newTokenPrice;
        emit TokenPriceUpdated(oldPrice, newTokenPrice);
    }

    /**
     * @dev Updates the minimum purchase threshold in USDT/USDC
     * @param _minThresholdLimit New minimum threshold in USDT/USDC (with 6 decimals)
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - New threshold must be greater than 0
     */
    function setMinThreshold(uint256 _minThresholdLimit) external onlyOwner {
        require(_minThresholdLimit > 0, "Threshold must be greater than 0");
                minThresholdLimit = _minThresholdLimit;
        emit MinThresholdUpdated(_minThresholdLimit);
    }

    /**
     * @dev Pauses the contract, preventing new token purchases
     * 
     * Requirements:
     * - Caller must be the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract, allowing token purchases to resume
     * 
     * Requirements:
     * - Caller must be the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ WITHDRAWAL FUNCTIONS ============
    
    /**
     * @dev Allows the contract owner to withdraw tokens from the contract
     * @param tokenAddress Address of the token contract to withdraw
     * @param amount Amount of tokens to withdraw (will be adjusted to available balance if needed)
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - Amount must be greater than 0
     * - Contract must have tokens to withdraw
     * 
     * Note: Tokens are transferred to the treasury wallet
     */
    function withdrawTokens(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(tokenAddress != address(0), "Invalid token address");

        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        if (amount > balance) {
            amount = balance;
        }

        token.safeTransfer(treasuryWallet, amount);
        emit TokensWithdrawn(msg.sender, amount);
    }

}
