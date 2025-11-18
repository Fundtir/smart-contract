// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FundtirVesting
 * @dev A comprehensive vesting contract for Fundtir tokens that supports multiple vesting schedules
 *      with configurable cliff periods, instant unlocks, and release frequencies.
 *
 * Key Features:
 * - Multiple vesting schedules per user
 * - Configurable cliff periods and instant unlock percentages
 * - Linear vesting with customizable release frequency
 * - Role-based access control for schedule creation
 * - Support for both user-initiated and admin-initiated token claims
 *
 * @author Fundtir Team
 */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FundtirVesting is Ownable2Step, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The Fundtir token contract that will be vested
    IERC20 immutable token;

    /// @dev Role identifier for account managers who can create vesting schedules
    bytes32 public constant ACCOUNT_MANAGER_ROLE =
        keccak256("ACCOUNT_MANAGER_ROLE");

    /**
     * @dev Structure representing a single vesting schedule for a user
     * @param scheduleId Unique identifier for this vesting schedule
     * @param totalAmount Total amount of tokens in this vesting schedule
     * @param instantUnlock Percentage of tokens (0-100) released immediately upon schedule creation
     * @param cliffPeriod Time in seconds before any vesting begins (after instant unlock)
     * @param vestingPeriod Total time in seconds for the complete vesting process
     * @param startTime Block timestamp when the vesting schedule was created
     * @param tokensReleased Total amount of tokens already released to the user
     * @param frequency Time period in seconds between vesting token release events (vesting releases)
     */
    struct VestingSchedule {
        uint256 scheduleId; // Unique schedule identifier
        uint256 totalAmount; // Total tokens in this schedule
        uint256 instantUnlock; // Percentage (0-100) released immediately
        uint256 cliffPeriod; // Seconds before vesting starts (stored internally)
        uint256 vestingPeriod; // Total vesting duration in seconds (stored internally)
        uint256 startTime; // Schedule creation timestamp
        uint256 tokensReleased; // Amount already released
        uint256 frequency; // Release frequency in seconds (stored internally)
    }

    /// @dev Mapping from user address to their array of vesting schedules
    mapping(address => VestingSchedule[]) public userVestingSchedules;

    /// @dev Global counter for generating unique schedule IDs
    uint256 public nextScheduleId = 1;

    /// @dev Emitted when tokens are released to a user
    event TokensReleased(
        address indexed recipient,
        uint256 scheduleId,
        uint256 amount
    );

    /// @dev Emitted when admin withdraws tokens from the contract
    event TokensWithdrawn(address indexed admin, uint256 amount);

    /// @dev Emitted when a new vesting schedule is created
    event VestingScheduleCreated(
        address indexed recipient,
        uint256 indexed scheduleId,
        uint256 totalAmount,
        uint256 instantUnlock,
        uint256 cliffPeriod,
        uint256 vestingPeriod,
        uint256 frequency
    );

    /**
     * @dev Constructor initializes the vesting contract with admin roles and token address
     * @param _multiSigWallet Address that will have DEFAULT_ADMIN_ROLE (can withdraw tokens)
     * @param _managerWallet Address that will have ACCOUNT_MANAGER_ROLE (can create schedules)
     * @param _fundtirToken Address of the Fundtir token contract to be vested
     */
    constructor(
        address _multiSigWallet,
        address _managerWallet,
        address _fundtirToken
    ) Ownable(_multiSigWallet) {
        token = IERC20(_fundtirToken);
        _grantRole(DEFAULT_ADMIN_ROLE, _multiSigWallet);
        _grantRole(ACCOUNT_MANAGER_ROLE, _managerWallet);
    }

    /**
     * @dev Modifier to validate that a schedule ID exists and belongs to the specified recipient
     * @param recipient Address of the user who should own the schedule
     * @param scheduleId ID of the schedule to validate
     */
    modifier validScheduleId(address recipient, uint256 scheduleId) {
        require(
            scheduleId > 0 && scheduleId < nextScheduleId,
            "Invalid schedule ID"
        );
        bool found = false;
        VestingSchedule[] memory schedules = userVestingSchedules[recipient];
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].scheduleId == scheduleId) {
                found = true;
                break;
            }
        }
        require(found, "Schedule not found");
        _;
    }

    /**
     * @dev Creates a new vesting schedule for a recipient
     * @param recipient Address of the user who will receive the vested tokens
     * @param totalAmount Total amount of tokens to be vested
     * @param instantUnlock Percentage (0-100) of tokens to release immediately
     * @param cliffPeriod Time in days before vesting begins (after instant unlock) - converted to seconds internally
     * @param vestingPeriod Total vesting duration in days - converted to seconds internally
     * @param frequency Time period in days between vesting token release events (vesting releases) - converted to seconds internally
     * @return scheduleId Unique identifier for the created vesting schedule
     *
     * Requirements:
     * - Caller must have ACCOUNT_MANAGER_ROLE or DEFAULT_ADMIN_ROLE
     * - totalAmount must be greater than 0
     * - instantUnlock must be between 0 and 100
     * - frequency must be greater than 0
     * - vestingPeriod must be greater than or equal to frequency
     *   This ensures at least one complete frequency period fits within the vesting period
     *   (after cliff), resulting in at least 2 vesting releases (not counting instant unlock).
     * - Caller must have sufficient token allowance
     */
    function createVestingSchedule(
        address recipient,
        uint256 totalAmount,
        uint256 instantUnlock, // in percentage
        uint256 cliffPeriod, // in days
        uint256 vestingPeriod, // in days
        uint256 frequency // in days
    ) external returns (uint256 scheduleId) {
        require(
            hasRole(ACCOUNT_MANAGER_ROLE, msg.sender) ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller not authorized"
        );
        require(totalAmount > 0, "Amount must be greater than 0");
        require(instantUnlock <= 100, "Unlock limit exceed");
        require(frequency > 0, "Frequency must be positive");
        require(
            vestingPeriod >= frequency,
            "Vesting period must be >= frequency"
        );
        require(
            vestingPeriod >= cliffPeriod,
            "Vesting period must be >= cliff period"
        );

        scheduleId = nextScheduleId++;

        // Create new vesting schedule
        VestingSchedule memory newSchedule = VestingSchedule({
            scheduleId: scheduleId,
            totalAmount: totalAmount,
            instantUnlock: instantUnlock,
            cliffPeriod: cliffPeriod * 1 days,
            vestingPeriod: vestingPeriod * 1 days,
            startTime: block.timestamp,
            tokensReleased: 0,
            frequency: frequency * 1 days
        });

        // Add to user's vesting schedules
        userVestingSchedules[recipient].push(newSchedule);

        // Transfer tokens from caller to contract
        token.safeTransferFrom(msg.sender, address(this), totalAmount);

        // Release immediate unlock tokens if any
        if ((totalAmount * instantUnlock) / 100 > 0) {
            _releaseImmediateTokens(recipient, scheduleId);
        }

        emit VestingScheduleCreated(
            recipient,
            scheduleId,
            totalAmount,
            instantUnlock,
            cliffPeriod,
            vestingPeriod,
            frequency
        );

        return scheduleId;
    }

    /**
     * @dev Internal function to release instant unlock tokens immediately after schedule creation
     * @param recipient Address of the user receiving the tokens
     * @param scheduleId ID of the schedule to release instant tokens for
     */
    function _releaseImmediateTokens(
        address recipient,
        uint256 scheduleId
    ) private {
        VestingSchedule[] storage schedules = userVestingSchedules[recipient];
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].scheduleId == scheduleId) {
                uint256 immediateTokens = (schedules[i].totalAmount *
                    schedules[i].instantUnlock) / 100;
                schedules[i].tokensReleased += immediateTokens;

                token.safeTransfer(recipient, immediateTokens);
                emit TokensReleased(recipient, scheduleId, immediateTokens);
                break;
            }
        }
    }

    /**
     * @dev Calculates the amount of tokens that can be released for a specific vesting schedule
     * @param recipient Address of the user who owns the vesting schedule
     * @param scheduleId ID of the vesting schedule to check
     * @return Amount of tokens that can be claimed at the current time
     *
     * This function implements linear vesting with the following logic:
     * 1. If before cliff period: return 0
     * 2. If after cliff period: calculate based on time elapsed and frequency
     * 3. Handle edge cases for final vesting release to ensure all tokens are eventually claimable
     * 
     * Note: The formula calculates total vesting releases as: 1 + ((vestingPeriod - cliffPeriod) / frequency)
     * This ensures at least 2 vesting releases when vestingPeriod >= frequency.
     */
    function getReleasableAmount(
        address recipient,
        uint256 scheduleId
    ) public view validScheduleId(recipient, scheduleId) returns (uint256) {
        VestingSchedule memory schedule = _getSchedule(recipient, scheduleId);

        uint256 totalTimePassed = block.timestamp - schedule.startTime;

        if (totalTimePassed < schedule.cliffPeriod) return 0;

        // Calculate total number of vesting releases (not counting instant unlock)
        // Formula: 1 + ((vestingPeriod - cliffPeriod) / frequency)
        // When vestingPeriod == frequency and cliffPeriod == 0: 1 + 1 = 2 releases
        // This ensures at least 2 vesting releases when vestingPeriod >= frequency
        uint256 totalVestingReleases = 1 +
            ((schedule.vestingPeriod - schedule.cliffPeriod) /
                schedule.frequency);
        uint256 timeAfterCliff = totalTimePassed - schedule.cliffPeriod;
        // Calculate how many vesting releases have passed (1-based counting)
        uint256 vestingReleasesPassed = 1 + (timeAfterCliff / schedule.frequency);

        // Clamp to totalVestingReleases (avoid overflow)
        if (vestingReleasesPassed > totalVestingReleases) {
            vestingReleasesPassed = totalVestingReleases;
        }
        uint256 instantUnlockAmount = (schedule.totalAmount *
            schedule.instantUnlock) / 100;

        uint256 totalVestingTokens = schedule.totalAmount - instantUnlockAmount;
        uint256 totalVestedSoFar;

        if (vestingReleasesPassed == totalVestingReleases) {
            // Final vesting release: release everything remaining
            totalVestedSoFar = totalVestingTokens;
        } else {
            totalVestedSoFar =
                (totalVestingTokens * vestingReleasesPassed) /
                totalVestingReleases;
        }

        uint256 alreadyReleasedVesting = schedule.tokensReleased >
            instantUnlockAmount
            ? schedule.tokensReleased - instantUnlockAmount
            : 0;

        if (totalVestedSoFar > alreadyReleasedVesting) {
            return totalVestedSoFar - alreadyReleasedVesting;
        }

        return 0;
    }

    /**
     * @dev Allows a user to claim tokens from a specific vesting schedule
     * @param scheduleId ID of the vesting schedule to claim tokens from
     *
     * Requirements:
     * - Caller must be a vesting participant
     * - Schedule ID must be valid and belong to the caller
     * - There must be tokens available to claim
     */
    function claimTokens(
        uint256 scheduleId
    ) external nonReentrant validScheduleId(msg.sender, scheduleId) {
        uint256 amountToRelease = getReleasableAmount(msg.sender, scheduleId);
        require(amountToRelease > 0, "Tokens Unavailable");

        _updateScheduleTokensReleased(msg.sender, scheduleId, amountToRelease);

        token.safeTransfer(msg.sender, amountToRelease);

        emit TokensReleased(msg.sender, scheduleId, amountToRelease);
    }

    /**
     * @dev Allows a user to claim all available tokens from all their vesting schedules at once
     *
     * Requirements:
     * - Caller must be a vesting participant
     * - There must be at least one token available to claim
     */
    function claimAllTokens() external nonReentrant {
        VestingSchedule[] storage schedules = userVestingSchedules[msg.sender];
        uint256 totalAmountToRelease = 0;

        for (uint256 i = 0; i < schedules.length; i++) {
            uint256 releasableAmount = getReleasableAmount(
                msg.sender,
                schedules[i].scheduleId
            );
            if (releasableAmount > 0) {
                schedules[i].tokensReleased += releasableAmount;
                totalAmountToRelease += releasableAmount;
                emit TokensReleased(
                    msg.sender,
                    schedules[i].scheduleId,
                    releasableAmount
                );
            }
        }

        require(totalAmountToRelease > 0, "No tokens available");
        token.safeTransfer(msg.sender, totalAmountToRelease);
    }

    /**
     * @dev Internal function to update the tokens released counter for a specific schedule
     * @param recipient Address of the user who owns the schedule
     * @param scheduleId ID of the schedule to update
     * @param amount Amount of tokens that were just released
     */
    function _updateScheduleTokensReleased(
        address recipient,
        uint256 scheduleId,
        uint256 amount
    ) private {
        VestingSchedule[] storage schedules = userVestingSchedules[recipient];
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].scheduleId == scheduleId) {
                schedules[i].tokensReleased += amount;
                break;
            }
        }
    }

    /**
     * @dev Internal function to retrieve a specific vesting schedule
     * @param recipient Address of the user who owns the schedule
     * @param scheduleId ID of the schedule to retrieve
     * @return VestingSchedule The requested vesting schedule
     * @dev Reverts if schedule is not found
     */
    function _getSchedule(
        address recipient,
        uint256 scheduleId
    ) private view returns (VestingSchedule memory) {
        VestingSchedule[] memory schedules = userVestingSchedules[recipient];
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].scheduleId == scheduleId) {
                return schedules[i];
            }
        }
        revert("Schedule not found");
    }

    // ============ VIEW FUNCTIONS FOR BETTER UX ============

    /**
     * @dev Returns all vesting schedules for a specific user
     * @param user Address of the user to query
     * @return Array of all vesting schedules for the user
     */
    function getUserVestingSchedules(
        address user
    ) external view returns (VestingSchedule[] memory) {
        return userVestingSchedules[user];
    }

    /**
     * @dev Returns the number of active vesting schedules for a user
     * @param user Address of the user to query
     * @return Number of vesting schedules
     */
    function getActiveSchedulesCount(
        address user
    ) external view returns (uint256) {
        return userVestingSchedules[user].length;
    }

    /**
     * @dev Returns a specific vesting schedule by ID
     * @param user Address of the user who owns the schedule
     * @param scheduleId ID of the schedule to retrieve
     * @return VestingSchedule The requested vesting schedule
     */
    function getScheduleById(
        address user,
        uint256 scheduleId
    ) external view returns (VestingSchedule memory) {
        return _getSchedule(user, scheduleId);
    }

    /**
     * @dev Returns the total amount of tokens vested across all schedules for a user
     * @param user Address of the user to query
     * @return total Total amount of tokens in all vesting schedules
     */
    function getTotalVestedAmount(
        address user
    ) external view returns (uint256 total) {
        VestingSchedule[] memory schedules = userVestingSchedules[user];
        total = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            total += schedules[i].totalAmount;
        }
        return total;
    }

    /**
     * @dev Returns the total amount of tokens already released across all schedules for a user
     * @param user Address of the user to query
     * @return total Total amount of tokens already released
     */
    function getTotalReleasedAmount(
        address user
    ) external view returns (uint256 total) {
        VestingSchedule[] memory schedules = userVestingSchedules[user];
        total = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            total += schedules[i].tokensReleased;
        }
        return total;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Allows the contract owner to withdraw tokens from the contract
     * @param tokenAddress Address of the token contract to withdraw
     * @param amount Amount of tokens to withdraw (will be adjusted to available balance if needed)
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Contract must have tokens to withdraw
     *
     * Note: This function is intended for emergency situations or to recover accidentally sent tokens
     */
    function withdrawTokens(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        IERC20 _token = IERC20(tokenAddress);
        require(_token.balanceOf(address(this)) > 0, "Insufficient Tokens");
        if (_token.balanceOf(address(this)) < amount) {
            amount = _token.balanceOf(address(this));
        }
        require(_token.transfer(owner(), amount), "Transfer Failed");
        emit TokensWithdrawn(msg.sender, amount);
    }
}
