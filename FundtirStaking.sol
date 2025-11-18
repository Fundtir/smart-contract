// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FNDRStaking
 * @notice Stake FNDR to earn USDT-denominated interest and participate in timestamp-based dividends.
 * @dev
 * - APY values are expressed in basis points (1% = 100 bps).
 * - Interest is computed in FNDR and paid out in USDT using `fndrPriceInUSDT` (scaled by 1e18).
 * - Dividend distributions snapshot eligible stakes that are at least `MIN_DIVIDEND_LOCK` old.
 */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FNDRStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice FNDR token that users stake in this contract.
    IERC20 public immutable fundtirToken;
    /// @notice USDT token used to pay interest and dividends.
    IERC20 public usdtToken;
    /// @dev Decimals of the Fundtir token (stored for efficiency, retrieved via decimals() call)
    uint8 public immutable fundtirDecimals;
    /// @dev Decimals of the USDT token (stored for efficiency, retrieved via decimals() call)
    uint8 public immutable usdtDecimals;
    /// @notice Minimum stake amount enforced to mitigate DoS via dust stakes.
    uint256 public minStakeAmount;
    /// @notice Minimum stake age required to be included in a dividend snapshot.
    uint256 public constant MIN_DIVIDEND_LOCK = 60 days;
    /// @notice Minimum waiting period before undistributed funds can be recovered (after distribution creation).
    uint256 public constant MIN_RECOVERY_WAIT_PERIOD = 60 days;

    /// @dev Decimals for token price (18 decimals format)
    uint8 public constant FUNDTIR_PRICE_DECIMALS = 18;

    /// @notice Price of 1 FNDR in USDT, scaled by 1e18 (e.g., 0.5 USDT = 0.5e18).
    uint256 public fndrPriceInUSDT;
    /// @notice Sum of all currently staked FNDR (across all users and stakes).
    uint256 public totalStakedAmount;

    /// @notice APY rates for the four staking plans, expressed in basis points.
    uint256 public plan1Apy = 897;
    uint256 public plan2Apy = 1435;
    uint256 public plan3Apy = 2152;
    uint256 public plan4Apy = 2869;

    /// @notice Staking durations for plans 1 to 4 respectively.
    uint256 public plan1Days = 90 days;
    uint256 public plan2Days = 365 days;
    uint256 public plan3Days = 730 days;
    uint256 public plan4Days = 1460 days;
    /// @notice Total USDT reserved to honor all active dividend distributions.
    uint256 public totalDividendsAllocated; // Sum of USDT reserved for all distributions
    /// @notice Total USDT notionally reserved for staking interest (worst-case projection).
    uint256 public totalInterestAllocated; // Sum of USDT reserved for staking interest
    /// @notice Number of distributions created so far (auto-incrementing id).
    uint256 public distributionCounter;

    /// @notice A single stake position for a user.
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 apy;
        uint256 usdtInterestSnapshot;
        bool withdrawn;
    }

    /// @notice Metadata captured when a dividend distribution is created.
    struct Distribution {
        uint256 id;
        uint256 timestamp;
        uint256 totalAmount;
        uint256 eligibleTotal;
        uint256 claimedAmount; // Track total claimed amount from this distribution
        bool exists;
    }
    /// @notice List of addresses that currently have a non-zero active stake.
    address[] public activeStakers;
    /// @dev Index of an active staker in `activeStakers` (used for O(1) removals).
    mapping(address => uint256) private activeStakerIndex;
    /// @notice All stake positions for a given user.
    mapping(address => Stake[]) public stakes;
    /// @notice Distribution data by distribution id.
    mapping(uint256 => Distribution) public distributions;
    /// @notice Tracks whether a user has already claimed from a given distribution.
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(address => uint256) private _currentStaked;
    /// @notice Eligible stake amount per-user captured at distribution creation time.
    mapping(uint256 => mapping(address => uint256))
        public distributionUserEligible;

    // Events
    /// @notice Emitted when a user stakes FNDR.
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 duration,
        uint256 apy
    );
    /// @notice Emitted when a user unstakes and receives USDT interest.
    event Unstaked(address indexed user, uint256 amount, uint256 usdtInterest);
    /// @notice Emitted when the FNDR price used for conversions is updated.
    event FNDRPriceUpdated(uint256 newPrice);
    /// @notice Emitted when the FNDR MinStakeAmount is updated.
    event MinStakeAmountUpdated(uint256 newMinAmount);
    /// @notice Emitted when a dividend distribution starts.
    event DistributionStarted(
        uint256 indexed id,
        uint256 totalAmount,
        uint256 eligibleTotal
    );
    /// @notice Emitted when a user claims their dividend share.
    event DividendClaimed(
        uint256 indexed id,
        address indexed user,
        uint256 amount
    );
    /// @notice Emitted when tokens are deposited by the owner.
    event AdminDeposit(address indexed admin, address token, uint256 amount);
    /// @notice Emitted when tokens are withdrawn by the owner.
    event AdminWithdraw(address indexed admin, address token, uint256 amount);
    /// @notice Emitted when APY values are updated by the owner.
    event APYUpdated(uint256 p1, uint256 p2, uint256 p3, uint256 p4);
    /// @notice Emitted when plan durations are updated by the owner.
    event PlanDaysUpdated(uint256 d1, uint256 d2, uint256 d3, uint256 d4);
    /// @notice Emitted when undistributed funds are recovered from a distribution.
    event UndistributedFundsRecovered(
        uint256 indexed distributionId,
        address indexed admin,
        uint256 amount
    );

    constructor(
        address _multiSigOwner,
        address _fundtirToken,
        address _usdtToken,
        uint256 _initialFNDRPrice
    ) Ownable(_multiSigOwner) {
        require(_multiSigOwner != address(0), "owner 0");
        require(_fundtirToken != address(0), "fundtirToken 0");
        require(_usdtToken != address(0), "usdtToken 0");
        require(_initialFNDRPrice > 0, "price must be > 0");

        fundtirToken = IERC20(_fundtirToken);
        usdtToken = IERC20(_usdtToken);
        uint8 _fundtirDecimals = IERC20Metadata(_fundtirToken).decimals();
        fundtirDecimals = _fundtirDecimals;
        usdtDecimals = IERC20Metadata(_usdtToken).decimals();
        minStakeAmount = 100 * 10 ** _fundtirDecimals;
        fndrPriceInUSDT = _initialFNDRPrice;
    }

    // ======== STAKING FUNCTIONS ========
    function _addActiveStaker(address user) internal {
        if (_currentStaked[user] == 0) {
            activeStakerIndex[user] = activeStakers.length;
            activeStakers.push(user);
        }
    }

    function _removeActiveStaker(address user) internal {
        if (_currentStaked[user] == 0 && activeStakers.length > 0) {
            uint256 index = activeStakerIndex[user];
            address lastUser = activeStakers[activeStakers.length - 1];
            activeStakers[index] = lastUser;
            activeStakerIndex[lastUser] = index;
            activeStakers.pop();
            delete activeStakerIndex[user];
        }
    }

    /**
     * @notice Stake FNDR into a specific plan.
     * @param amount FNDR amount to stake.
     * @param plan Plan id in {1,2,3,4} selecting APY and duration.
     * @dev Emits {Staked}. Transfers FNDR from caller to this contract.
     */
    function stake(uint256 amount, uint256 plan) external nonReentrant {
        require(amount > 0, "Invalid amount");
        require(amount >= minStakeAmount, "Amount below minimum stake");
        (uint256 apy, uint256 duration) = getPlanDetails(plan);

        fundtirToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 interest = calculateInterest(amount, apy, duration);
        uint256 usdtInterest = convertFNDRToUSDT(interest);
        totalInterestAllocated += usdtInterest;
        require(
            usdtToken.balanceOf(address(this)) >=
                (totalInterestAllocated + totalDividendsAllocated),
            "Insufficient USDT balance for allocations"
        );
        stakes[msg.sender].push(
            Stake({
                amount: amount,
                startTime: block.timestamp,
                duration: duration,
                apy: apy,
                usdtInterestSnapshot: usdtInterest,
                withdrawn: false
            })
        );
        totalStakedAmount += amount;
        // Add to active stakers if not already
        _addActiveStaker(msg.sender);
        _currentStaked[msg.sender] += amount;

        emit Staked(msg.sender, amount, duration, apy);
    }

    /**
     * @notice Unstake a previously created stake after its lockup has elapsed.
     * @param stakeIndex Index of the user's stake in `stakes[msg.sender]`.
     * @dev Emits {Unstaked}. Transfers principal (FNDR) and interest (USDT).
     */
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < stakes[msg.sender].length, "Invalid index");
        Stake storage s = stakes[msg.sender][stakeIndex];
        require(!s.withdrawn, "Already withdrawn");
        require(block.timestamp >= s.startTime + s.duration, "Stake locked");

        uint256 usdtInterest = s.usdtInterestSnapshot;
        totalInterestAllocated -= usdtInterest;
        require(
            usdtToken.balanceOf(address(this)) >= usdtInterest,
            "Insufficient USDT balance"
        );

        s.withdrawn = true;

        fundtirToken.safeTransfer(msg.sender, s.amount);
        usdtToken.safeTransfer(msg.sender, usdtInterest);

        totalStakedAmount -= s.amount;
        _currentStaked[msg.sender] -= s.amount;

        // Remove from active stakers if user has no more stake
        _removeActiveStaker(msg.sender);

        emit Unstaked(msg.sender, s.amount, usdtInterest);
    }

    // ======== APY AND PRICING HELPERS ========

    /**
     * @notice Get APY and duration for a plan.
     * @param plan Plan id in {1,2,3,4}.
     * @return apy Basis points APY.
     * @return duration Plan duration in seconds.
     */
    function getPlanDetails(
        uint256 plan
    ) public view returns (uint256 apy, uint256 duration) {
        if (plan == 1) return (plan1Apy, plan1Days);
        if (plan == 2) return (plan2Apy, plan2Days);
        if (plan == 3) return (plan3Apy, plan3Days);
        if (plan == 4) return (plan4Apy, plan4Days);
        revert("Invalid plan");
    }

    /**
     * @notice Calculate linear interest in FNDR for a given stake specification.
     * @param amount Staked FNDR principal.
     * @param apy APY in basis points (bps).
     * @param duration Elapsed time in seconds (capped by plan duration).
     * @return Interest amount denominated in FNDR units.
     */
    function calculateInterest(
        uint256 amount,
        uint256 apy,
        uint256 duration
    ) public pure returns (uint256) {
        return (amount * apy * duration) / (365 days * 10000);
    }

    /**
     * @notice Convert a FNDR amount to USDT using `fndrPriceInUSDT`.
     * @param fndrAmount Amount in FNDR (18 decimals).
     * @return Equivalent USDT amount (6 decimals).
     */
    function convertFNDRToUSDT(
        uint256 fndrAmount
    ) public view returns (uint256) {
        require(fndrPriceInUSDT > 0, "FNDR price not set");
        // Compute amount in 18-decimal USDT units then scale down to 6 decimals
        uint256 usdtAmount = (fndrAmount *
            fndrPriceInUSDT *
            10 ** usdtDecimals) /
            (10 ** (fundtirDecimals + FUNDTIR_PRICE_DECIMALS));
        return usdtAmount;
    }

    // ======== DIVIDEND FUNCTIONS ========

    /**
     * @notice Update the FNDR price used to convert FNDR interest to USDT.
     * @param newPrice Price of 1 FNDR in USDT (scaled by 1e18).
     * @dev Emits {FNDRPriceUpdated}.
     */
    function updateFNDRPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be > 0");
        fndrPriceInUSDT = newPrice;
        emit FNDRPriceUpdated(newPrice);
    }

    /**
     * @notice Updates the minimum staking amount required to participate.
     * @param newMinAmount The new minimum staking amount (scaled by 1e18).
     * @dev Only the contract owner can call this function.
     *      Reverts if the provided amount is zero.
     *      Emits a {MinStakeAmountUpdated} event upon successful update.
     */
    function updateMinStakeAmount(uint256 newMinAmount) external onlyOwner {
        require(newMinAmount > 0, "Price must be > 0");
        minStakeAmount = newMinAmount;
        emit MinStakeAmountUpdated(newMinAmount);
    }

    /**
     * @notice Start a dividend distribution denominated in USDT.
     * @param totalAmount USDT amount to allocate across eligible stakers.
     * @dev Emits {DistributionStarted}. Takes a snapshot of eligible stakes.
     */
    function startDistribution(
        uint256 totalAmount
    ) external onlyOwner nonReentrant {
        require(totalAmount > 0, "Zero amount");
        require(
            usdtToken.balanceOf(address(this)) >=
                (totalAmount +
                    totalDividendsAllocated +
                    totalInterestAllocated),
            "Insufficient USDT"
        );

        uint256 eligibleTotal = 0;

        distributionCounter += 1;

        // Snapshot eligible stakes
        for (uint256 i = 0; i < activeStakers.length; i++) {
            address user = activeStakers[i];
            uint256 userEligible = _eligibleStakeAmount(user, block.timestamp);
            if (userEligible > 0) {
                distributionUserEligible[distributionCounter][
                    user
                ] = userEligible;
                eligibleTotal += userEligible;
            }
        }

        require(eligibleTotal > 0, "No eligible stakers");

        distributions[distributionCounter] = Distribution({
            id: distributionCounter,
            timestamp: block.timestamp,
            totalAmount: totalAmount,
            eligibleTotal: eligibleTotal,
            claimedAmount: 0,
            exists: true
        });
        totalDividendsAllocated += totalAmount;
        emit DistributionStarted(
            distributionCounter,
            totalAmount,
            eligibleTotal
        );
    }

    /**
     * @notice Claim caller's share from a distribution.
     * @param distributionId Distribution identifier.
     * @dev Emits {DividendClaimed}.
     */
    function claimFromDistribution(
        uint256 distributionId
    ) external nonReentrant {
        Distribution storage d = distributions[distributionId];
        require(
            d.exists,
            "Distribution does not exist or has expired/was recovered by the admin"
        );
        require(!hasClaimed[distributionId][msg.sender], "Already claimed");

        uint256 userStake = distributionUserEligible[distributionId][
            msg.sender
        ];
        require(userStake > 0, "Zero stake at snapshot");

        uint256 share = (userStake * d.totalAmount) / d.eligibleTotal;

        // Mark as claimed even if share is zero to prevent repeated attempts
        hasClaimed[distributionId][msg.sender] = true;

        // Only transfer and update if share is greater than zero
        if (share > 0) {
            usdtToken.safeTransfer(msg.sender, share);
            totalDividendsAllocated -= share;
            d.claimedAmount += share;
        }

        emit DividendClaimed(distributionId, msg.sender, share);
    }

    function _eligibleStakeAmount(
        address user,
        uint256 atTimestamp
    ) internal view returns (uint256) {
        uint256 sum = 0;
        Stake[] memory arr = stakes[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (
                !arr[i].withdrawn &&
                arr[i].startTime + MIN_DIVIDEND_LOCK <= atTimestamp
            ) {
                sum += arr[i].amount;
            }
        }
        return sum;
    }

    // ======== ADMIN FUNCTIONS ========

    /**
     * @notice Owner-only deposit of ERC20 tokens (FNDR or USDT).
     * @param tokenAddr Token address to deposit.
     * @param amount Amount to transfer from owner to this contract.
     * @dev Emits {AdminDeposit}. Requires prior approval by owner.
     */
    function adminDeposit(
        address tokenAddr,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(amount > 0, "Zero amount");
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        emit AdminDeposit(msg.sender, tokenAddr, amount);
    }

    /**
     * @notice Owner-only withdrawal of ERC20 tokens.
     * @param tokenAddr Token address to withdraw.
     * @param amount Amount to withdraw.
     * @param to Recipient address.
     * @dev Emits {AdminWithdraw}. Enforces FNDR availability and USDT interest reserve.
     */
    function adminWithdraw(
        address tokenAddr,
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        IERC20 token = IERC20(tokenAddr);
        if (tokenAddr == address(fundtirToken)) {
            require(
                token.balanceOf(address(this)) >= amount + totalStakedAmount,
                "Insufficient available FNDR"
            );
        } else if (tokenAddr == address(usdtToken)) {
            require(
                token.balanceOf(address(this)) >=
                    amount + totalInterestAllocated + totalDividendsAllocated,
                "Insufficient available USDT"
            );
        }
        token.safeTransfer(to, amount);
        emit AdminWithdraw(msg.sender, tokenAddr, amount);
    }

    /**
     * @notice Recover undistributed funds from a distribution.
     * @param distributionId Distribution identifier.
     * @param to Recipient address for the undistributed funds.
     * @dev Allows admin to recover funds that were allocated but not claimed.
     *      This can happen due to rounding down or unclaimed distributions.
     *      Requires MIN_RECOVERY_WAIT_PERIOD to have elapsed since distribution creation
     *      to ensure users have adequate time to claim their funds.
     *      Emits {UndistributedFundsRecovered}.
     */
    function recoverUndistributedFunds(
        uint256 distributionId,
        address to
    ) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        Distribution storage d = distributions[distributionId];
        require(
            d.exists,
            "Distribution does not exist or has expired/was recovered by the admin"
        );
        require(
            block.timestamp >= d.timestamp + MIN_RECOVERY_WAIT_PERIOD,
            "Recovery period not elapsed"
        );
        require(d.claimedAmount <= d.totalAmount, "Invalid claimed amount");

        uint256 undistributed = d.totalAmount - d.claimedAmount;
        require(undistributed > 0, "No undistributed funds");

        // Update tracking: mark the remaining amount as claimed
        d.claimedAmount = d.totalAmount;
        totalDividendsAllocated -= undistributed;

        usdtToken.safeTransfer(to, undistributed);
        d.exists = false;
        emit UndistributedFundsRecovered(
            distributionId,
            msg.sender,
            undistributed
        );
    }

    /**
     * @notice Update APY values for all plans.
     * @param _p1 New APY for plan 1 in bps.
     * @param _p2 New APY for plan 2 in bps.
     * @param _p3 New APY for plan 3 in bps.
     * @param _p4 New APY for plan 4 in bps.
     * @dev Emits {APYUpdated}. Each value must be (0, 10000].
     */
    function updateAPY(
        uint256 _p1,
        uint256 _p2,
        uint256 _p3,
        uint256 _p4
    ) external onlyOwner {
        require(
            _p1 > 0 &&
                _p2 > 0 &&
                _p3 > 0 &&
                _p4 > 0 &&
                _p1 <= 10000 &&
                _p2 <= 10000 &&
                _p3 <= 10000 &&
                _p4 <= 10000,
            "Invalid APY"
        );
        plan1Apy = _p1;
        plan2Apy = _p2;
        plan3Apy = _p3;
        plan4Apy = _p4;
        emit APYUpdated(_p1, _p2, _p3, _p4);
    }

    /**
     * @notice Update durations for all plans.
     * @param d1 New duration for plan 1 (seconds).
     * @param d2 New duration for plan 2 (seconds).
     * @param d3 New duration for plan 3 (seconds).
     * @param d4 New duration for plan 4 (seconds).
     * @dev Emits {PlanDaysUpdated}. All values must be > 0.
     */
    function updatePlanDays(
        uint256 d1,
        uint256 d2,
        uint256 d3,
        uint256 d4
    ) external onlyOwner {
        require(d1 > 0 && d2 > 0 && d3 > 0 && d4 > 0, "days>0");
        plan1Days = d1;
        plan2Days = d2;
        plan3Days = d3;
        plan4Days = d4;
        emit PlanDaysUpdated(d1, d2, d3, d4);
    }

    // ======== VIEW FUNCTIONS ========
    /**
     * @notice Returns the pending staking reward (USDT) for a user based on all active stakes
     * @param user Address of the user
     * @return pendingReward USDT amount for all active stakes
     */
    /**
     * @notice Aggregate pending USDT interest for all active stakes of a user.
     * @param user User address.
     * @return pendingReward USDT-denominated interest accrued so far.
     */
    function getPendingInterest(
        address user
    ) external view returns (uint256 pendingReward) {
        Stake[] memory userStakes = stakes[user];
        uint256 totalPending = 0;
        uint256 nowTimestamp = block.timestamp;

        for (uint256 i = 0; i < userStakes.length; i++) {
            Stake memory s = userStakes[i];
            if (s.withdrawn) continue;

            // Cap duration to stake duration
            uint256 stakedTime = nowTimestamp > s.startTime + s.duration
                ? s.duration
                : nowTimestamp - s.startTime;

            if (stakedTime == 0) continue;

            uint256 fndrInterest = calculateInterest(
                s.amount,
                s.apy,
                stakedTime
            );
            uint256 usdtInterest = convertFNDRToUSDT(fndrInterest);
            totalPending += usdtInterest;
        }

        pendingReward = totalPending;
    }

    /**
     * @notice Return all stake positions for a user.
     * @param user User address.
     */
    function getUserStakes(
        address user
    ) external view returns (Stake[] memory) {
        return stakes[user];
    }

    /**
     * @notice Current total FNDR staked by a user (excluding withdrawn stakes).
     */
    function currentStakedOf(address user) external view returns (uint256) {
        return _currentStaked[user];
    }

    /**
     * @notice Current number of addresses with a non-zero active stake.
     */
    function stakeHoldersCount() external view returns (uint256) {
        return activeStakers.length;
    }

    /**
     * @notice Return the configured FNDR price in USDT (scaled by 1e18).
     */
    function getFNDRPrice() external view returns (uint256) {
        return fndrPriceInUSDT;
    }

    /**
     * @notice Preview the USDT interest for a hypothetical FNDR amount and plan.
     * @param fndrAmount Hypothetical FNDR principal.
     * @param plan Plan id in {1,2,3,4}.
     * @return USDT interest value using current price and APY.
     */
    function previewUSDTInterest(
        uint256 fndrAmount,
        uint256 plan
    ) external view returns (uint256) {
        (uint256 apy, uint256 duration) = getPlanDetails(plan);
        uint256 fndrInterest = calculateInterest(fndrAmount, apy, duration);
        return convertFNDRToUSDT(fndrInterest);
    }

    /**
     * @notice Return the USDT token address used by the contract.
     */
    function getUSDTTokenAddress() external view returns (address) {
        return address(usdtToken);
    }

    /**
     * @notice Return FNDR available for admin withdrawal (excludes staked amount).
     */
    function getAvailableFNDRBalance() external view returns (uint256) {
        return fundtirToken.balanceOf(address(this)) - totalStakedAmount;
    }
}
