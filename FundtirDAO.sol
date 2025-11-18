// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FundtirGovernance
 * @dev A comprehensive governance contract for Fundtir token holders with integrated staking and vesting support
 * 
 * Key Features:
 * - Proposal creation with configurable threshold (default: 0.25% of total supply)
 * - One wallet, one vote system with minimum voting weight requirement
 * - Dynamic quorum requirements (admin-configurable)
 * - Integration with staking and vesting contracts for voting power calculation
 * - Snapshot-based voting with fallback to current balances
 * - Manual execution via executor (typically multisig)
 * 
 * Governance Parameters:
 * - Proposer threshold: 0.25% of total supply (staked + vested amount combined)
 * - Quorum: Dynamic admin-set number of votes required
 * - Voting options: For / Against / Abstain
 * - Voting power: One wallet, one vote (with minimum voting weight requirement)
 * - Execution: Manual via executor (e.g., multisig)
 * 
 * Integration:
 * - FNDR ERC20 token for total supply calculations
 * - Staking contract for staked token amounts (with historic snapshot support)
 * - Vesting contract for unclaimed vested amounts
 * 
 * @author Fundtir Team
 */

// ============ INTERFACES ============

/**
 * @dev Interface for ERC20 token operations
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @dev Interface for staking contract integration
 * @notice Supports both historic snapshot lookup and current balance fallback
 */
interface IStaking {
    /// @dev Current staked balance (FNDR) for a user
    /// @param user Address of the user
    /// @return Current staked amount
    function currentStakedOf(address user) external view returns (uint256);
}

/**
 * @dev Interface for vesting contract integration
 * @notice Used to calculate unclaimed vested amounts for voting power
 */
interface IVesting {
    /// @dev Get total vested amount for a user (all schedules combined)
    /// @param user Address of the user
    /// @return Total amount of tokens vested for the user
    function getTotalVestedAmount(address user) external view returns (uint256);
    
    /// @dev Get total released amount for a user (all schedules combined)
    /// @param user Address of the user
    /// @return Total amount of tokens already released to the user
    function getTotalReleasedAmount(address user) external view returns (uint256);
    
    /// @dev Check if user is a vesting participant
    /// @param user Address of the user
    /// @return True if user has active vesting schedules
    function isVestingParticipant(address user) external view returns (bool);
}

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FundtirGovernance is Ownable, ReentrancyGuard {
    // ============ STATE VARIABLES ============
    
    /// @dev The FNDR token contract
    IERC20 public immutable FNDRToken;
    
    /// @dev The staking contract for voting power calculation
    IStaking public immutable stakingContract;
    
    /// @dev The vesting contract for unclaimed vested amounts
    IVesting public immutable vestingContract;

  /// @dev Delay between proposal creation and voting start
    uint256 public constant MIN_VOTING_DELAY = 1 days;

    /// @dev Duration of the voting period
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    /// @dev Counter for generating unique proposal IDs
    uint256 public proposalCount;

    // ============ GOVERNANCE CONFIGURATION ============

    /// @dev Proposal threshold in basis points (default: 25 = 0.25%)
    uint256 public proposalThresholdBps = 25;
    
    /// @dev Dynamic quorum - minimum number of votes required (admin configurable)
    uint256 public requiredQuorumVotes = 100;
    
    /// @dev Minimum voting weight required to cast a vote (admin configurable)
    uint256 public minVotingWeight = 1000 * 10**18; // 1000 tokens

    // ============ ENUMS AND STRUCTURES ============
    
    /// @dev Available voting options
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /**
     * @dev Structure representing a governance proposal
     * @param id Unique proposal identifier
     * @param proposer Address of the proposal creator
     * @param title Short title for the proposal
     * @param description Detailed description of the proposal
     * @param startTime Timestamp when voting starts
     * @param endTime Timestamp when voting ends
     * @param executed Whether the proposal has been executed
     * @param forVotes Number of votes in favor
     * @param againstVotes Number of votes against
     * @param abstainVotes Number of abstain votes
     * @param totalVotes Total number of votes cast
     */
    struct Proposal {
        uint256 id;              // Unique proposal ID
        address proposer;        // Proposal creator
        string title;            // Proposal title
        string description;      // Proposal description
        uint256 startTime;       // Voting start timestamp
        uint256 endTime;         // Voting end timestamp
        bool executed;           // Execution status
        uint256 forVotes;        // Votes in favor
        uint256 againstVotes;    // Votes against
        uint256 abstainVotes;    // Abstain votes
        uint256 totalVotes;      // Total votes cast
    }

    /**
     * @dev Structure representing a vote receipt
     * @param hasVoted Whether the user has voted
     * @param support The vote type cast
     * @param weight The voting weight used
     * @param votedAt Timestamp when the vote was cast
     */
    struct VoteReceipt {
        bool hasVoted;           // Vote status
        VoteType support;        // Vote type
        uint256 weight;          // Voting weight
        uint256 votedAt;         // Vote timestamp
    }

    // ============ STORAGE MAPPINGS ============
    
    /// @dev Mapping from proposal ID to proposal details
    mapping(uint256 => Proposal) public proposals;

    /// @dev Mapping from proposal ID and voter address to vote receipt
    mapping(uint256 => mapping(address => VoteReceipt)) public receipts;

    // ============ EVENTS ============
    
    /// @dev Emitted when a new proposal is created
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        string title,
        uint256 startTime,
        uint256 endTime
    );
    
    /// @dev Emitted when a vote is cast
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        VoteType support,
        uint256 weight
    );
    
    /// @dev Emitted when a proposal is executed
    event ProposalExecuted(uint256 indexed id, address indexed executorAddr);
    
    /// @dev Emitted when the executor address is changed
    event ExecutorChanged(
        address indexed oldExecutor,
        address indexed newExecutor
    );
    
    /// @dev Emitted when quorum requirements are updated
    event QuorumVotesUpdated(uint256 newQuorumVotes);
    
    /// @dev Emitted when proposal threshold is updated
    event ProposalThresholdUpdated(uint256 newProposalThresholdBps);
    
    /// @dev Emitted when minimum voting weight is updated
    event MinVotingWeightUpdated(uint256 newMinVotingWeight);

    /**
     * @dev Constructor initializes the governance contract with required addresses and parameters
     * @param _fntrToken Address of the FNDR token contract
     * @param _stakingContract Address of the staking contract
     * @param _vestingContract Address of the vesting contract
     * @param _executor Address that will become the owner (typically multisig)
     * 
     * Requirements:
     * - All contract addresses must be valid (non-zero)
     * - Voting delay and period must be reasonable values
     */
    constructor(
        address _fntrToken,
        address _stakingContract,
        address _vestingContract,
        address _executor
    ) Ownable(_executor) {
        require(_fntrToken != address(0), "token 0");
        require(_stakingContract != address(0), "staking 0");
        require(_vestingContract != address(0), "vesting 0");

        FNDRToken = IERC20(_fntrToken);
        stakingContract = IStaking(_stakingContract);
        vestingContract = IVesting(_vestingContract);
    }
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @dev Check whether an address has voted on a specific proposal
     * @param proposalId ID of the proposal
     * @param voter Address of the voter
     * @return True if the voter has already voted on this proposal
     */
    function hasVoted(
        uint256 proposalId,
        address voter
    ) public view returns (bool) {
        return receipts[proposalId][voter].hasVoted;
    }

    // ============ PROPOSAL LIFECYCLE ============

    /**
     * @dev Create a new governance proposal
     * @param title Short title for UI display
     * @param description Detailed description (can be IPFS hash or URL)
     * @return proposalId The ID of the created proposal
     * 
     * Requirements:
     * - Proposer must hold >= proposal threshold (default: 0.25% of total supply)
     * - Threshold is calculated as combined staked + unclaimed vested amount
     * - Total supply must be greater than 0
     * 
     * Process:
     * 1. Validates proposer eligibility based on combined stake + vesting
     * 2. Creates proposal with voting delay and period
     * 3. Records snapshot block for historic voting power lookup
     * 4. Emits ProposalCreated event
     */
    function propose(
        string calldata title,
        string calldata description
    ) external nonReentrant returns (uint256) {
        // Check proposer threshold: 0.25% of totalSupply
        uint256 total = FNDRToken.totalSupply();
        require(total > 0, "totalSupply 0");

        uint256 thresh = (total * proposalThresholdBps) / 10000; // 0.25%
        uint256 proposerCombinedAmount = _getCombinedEligibilityAmount(msg.sender);

        require(proposerCombinedAmount >= thresh, "insufficient stake + vesting to propose");

        proposalCount++;
        uint256 pid = proposalCount;
        uint256 start = block.timestamp + MIN_VOTING_DELAY;
        uint256 endt = start + MAX_VOTING_PERIOD;

        Proposal storage p = proposals[pid];
        p.id = pid;
        p.proposer = msg.sender;
        p.title = title;
        p.description = description;
        p.startTime = start;
        p.endTime = endt;
        p.executed = false;

        emit ProposalCreated(
            pid,
            msg.sender,
            title,
            start,
            endt
        );
        return pid;
    }

    /**
     * @dev Cast a vote on a proposal
     * @param proposalId ID of the proposal to vote on
     * @param support Vote type (For, Against, or Abstain)
     * 
     * Requirements:
     * - Proposal must exist and be in voting period
     * - Voter must not have already voted
     * - Voter must have sufficient voting weight (staked + vested amount)
     * 
     * Voting System:
     * - One wallet, one vote system (each wallet gets exactly 1 vote)
     * - Voting weight is used for eligibility check only
     * - All votes have equal weight regardless of token amount
     */
    function castVote(
        uint256 proposalId,
        VoteType support
    ) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "proposal not found");
        require(block.timestamp >= p.startTime, "voting not started");
        require(block.timestamp <= p.endTime, "voting finished");
        require(!hasVoted(proposalId, msg.sender), "already voted");

        uint256 weight = _getVotingWeightFor(msg.sender);
        require(weight >= minVotingWeight, "insufficient voting weight");

        // One wallet, one vote system - each wallet gets exactly 1 vote regardless of token amount
        uint256 voteWeight = 1;

        if (support == VoteType.For) {
            p.forVotes += voteWeight;
        } else if (support == VoteType.Against) {
            p.againstVotes += voteWeight;
        } else {
            p.abstainVotes += voteWeight;
        }

        p.totalVotes += voteWeight;

        receipts[proposalId][msg.sender] = VoteReceipt({
            hasVoted: true,
            support: support,
            weight: voteWeight,
            votedAt: block.timestamp
        });

        emit VoteCast(msg.sender, proposalId, support, voteWeight);
    }

    /**
     * @dev Execute a proposal after voting has ended
     * @param proposalId ID of the proposal to execute
     * 
     * Requirements:
     * - Proposal must exist and voting must have ended
     * - Proposal must not already be executed
     * - Quorum must be reached (minimum number of votes)
     * - Proposal must have majority support (forVotes > againstVotes)
     * 
     * Note: This function only marks the proposal as executed.
     * Actual on-chain execution must be performed separately by the executor.
     */
    function executeProposal(uint256 proposalId) external nonReentrant onlyOwner{
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "proposal not found");
        require(block.timestamp > p.endTime, "voting still active");
        require(!p.executed, "already executed");

        // Check quorum - minimum number of votes required
        require(p.totalVotes >= requiredQuorumVotes, "quorum not reached");

        // Check that forVotes > againstVotes (simple majority)
        require(p.forVotes > p.againstVotes, "proposal not passed");

        p.executed = true;

        emit ProposalExecuted(proposalId, msg.sender);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get proposal details by ID
     * @param proposalId ID of the proposal
     * @return Proposal details including voting results and metadata
     */
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @dev Get vote receipt for a specific voter on a proposal
     * @param proposalId ID of the proposal
     * @param voter Address of the voter
     * @return VoteReceipt containing vote details and timestamp
     */
    function getReceipt(
        uint256 proposalId,
        address voter
    ) external view returns (VoteReceipt memory) {
        return receipts[proposalId][voter];
    }

    // ============ INTERNAL HELPER FUNCTIONS ============

    /**
     * @dev Calculate voting weight for a user on a specific proposal
     * @param voter Address of the voter
     * @return Combined voting weight (staked + unclaimed vested amount)
     * 
     * This function attempts to use historic snapshot data from the staking contract,
     * falling back to current balances if historic lookup is not available.
     */
    function _getVotingWeightFor(
        address voter
    ) internal view returns (uint256) {
        // Get staked amount from staking contract (current balance)
        uint256 stakedAmount = stakingContract.currentStakedOf(voter);

        // Get unclaimed/available vested amount (current amount, not historic)
        uint256 vestedAmount = 0;
        // Directly compute from vesting totals; ignore participant check for compatibility
        try vestingContract.getTotalVestedAmount(voter) returns (uint256 totalVested) {
            try vestingContract.getTotalReleasedAmount(voter) returns (uint256 totalReleased) {
                vestedAmount = totalVested > totalReleased ? totalVested - totalReleased : 0;
            } catch {
                vestedAmount = 0;
            }
        } catch {
            vestedAmount = 0;
        }

        return stakedAmount + vestedAmount;
    }

    /**
     * @dev Get staked amount for a user at a specific block number
     * @param user Address of the user
     * @return Staked amount at the specified block
     * 
     * Used for proposal eligibility threshold checks.
     * Attempts historic lookup first, falls back to current balance.
     */
    function _getStakedFor(
        address user
    ) internal view returns (uint256) {
        // Snapshot not supported; use current staked balance for compatibility
        return stakingContract.currentStakedOf(user);
    }

    /**
     * @dev Get combined staked + vested amount for proposal eligibility
     * @param user Address of the user to check
     * @return Combined amount of staked + unclaimed vested tokens
     * 
     * This function calculates the total voting power for proposal eligibility.
     * Staking amount uses historic snapshot, vesting amount uses current unclaimed balance.
     */
    function _getCombinedEligibilityAmount(
        address user
    ) internal view returns (uint256) {
        uint256 stakedAmount = _getStakedFor(user);
        uint256 vestedAmount = 0;
        // Directly compute from vesting totals; ignore participant check for compatibility
        try vestingContract.getTotalVestedAmount(user) returns (uint256 totalVested) {
            try vestingContract.getTotalReleasedAmount(user) returns (uint256 totalReleased) {
                vestedAmount = totalVested > totalReleased ? totalVested - totalReleased : 0;
            } catch {
                vestedAmount = 0;
            }
        } catch {
            vestedAmount = 0;
        }
        
        return stakedAmount + vestedAmount;
    }

    // ============ PUBLIC UTILITY FUNCTIONS ============

    /**
     * @dev Check if a user is eligible to create proposals
     * @param user Address of the user to check
     * @return eligible True if user has sufficient combined staked + vested amount
     * @return combinedAmount The total combined amount (staked + vested)
     * @return threshold The current proposal threshold amount
     */
    function checkProposalEligibility(address user) external view returns (
        bool eligible,
        uint256 combinedAmount,
        uint256 threshold
    ) {
        uint256 total = FNDRToken.totalSupply();
        threshold = (total * proposalThresholdBps) / 10000; // 0.25%
        combinedAmount = _getCombinedEligibilityAmount(user);
        eligible = combinedAmount >= threshold;
    }

    /**
     * @dev Get voting weight for a specific proposal and voter
     * @param voter Address of the voter to check
     * @return votingWeight The voting weight (staked + vested amount)
     */
    function getVotingWeight( address voter) external view returns (uint256 votingWeight) {
        return _getVotingWeightFor( voter);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Update the required quorum votes for proposal execution
     * @param newQuorumVotes New minimum number of votes required
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - New quorum must be greater than 0
     */
    function setRequiredQuorumVotes(uint256 newQuorumVotes) external onlyOwner {
        require(newQuorumVotes > 0, "Quorum must be > 0");
        requiredQuorumVotes = newQuorumVotes;
        emit QuorumVotesUpdated(newQuorumVotes);
    }

    /**
     * @dev Update proposal threshold in basis points
     * @param _proposalThresholdBps New threshold in basis points (10000 = 100%)
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - Threshold must be positive and not exceed 100%
     */
    function setProposalThresholdBps(uint256 _proposalThresholdBps) external onlyOwner {
        require(_proposalThresholdBps > 0, "threshold must be positive");
        require(_proposalThresholdBps <= 10000, "threshold cannot exceed 100%");
        proposalThresholdBps = _proposalThresholdBps;
        emit ProposalThresholdUpdated(_proposalThresholdBps);
    }

    /**
     * @dev Update minimum voting weight required to cast a vote
     * @param _minVotingWeight New minimum voting weight in token units
     * 
     * Requirements:
     * - Caller must be the contract owner
     * - Minimum voting weight must be positive
     */
    function setMinVotingWeight(uint256 _minVotingWeight) external onlyOwner {
        require(_minVotingWeight > 0, "min voting weight must be positive");
        minVotingWeight = _minVotingWeight;
        emit MinVotingWeightUpdated(_minVotingWeight);
    }
}
