// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FundtirToken
 * @dev ERC20 token (FNTR) with burnable and permit functionality, and an
 *      initial fixed-supply distribution across predefined allocation
 *      categories at deployment time.
 *
 * Features:
 * - Standard ERC20 token functionality
 * - Burnable tokens (users can burn their own tokens)
 * - EIP-2612 permit functionality for gasless approvals
 * - Ownable with 2-step ownership transfer for security
 * - Fixed supply of 700 million tokens
 * - Initial distribution by fixed percentages to category addresses
 *
 * Allocation Breakdown (must sum to 100%):
 * - Marketing & Rewards: 10%
 * - Reserve / Operations: 15%
 * - Founding Team: 15%
 * - Private Sale: 15%
 * - Public Sale: 45%
 *
 * Note: The provided allocation addresses receive their respective shares
 * upon deployment. The `_adminWallet` is set as contract owner but does not
 * automatically receive tokens unless used as one of the allocation addresses.
 *
 * Author: Fundtir Team
 */
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract FundtirToken is ERC20, ERC20Burnable, ERC20Permit, Ownable2Step {
    /**
     * @dev Constructor initializes the Fundtir token and distributes the
     *      total fixed supply across allocation categories.
     * @param _adminWallet Address set as owner (Ownable2Step). Does not
     *        receive tokens by default unless also provided as an allocation.
     * @param _marketingRewards Recipient of 10% (Marketing & Rewards)
     * @param _reserveOperations Recipient of 15% (Reserve / Operations)
     * @param _foundingTeam Recipient of 15% (Founding Team)
     * @param _privateSale Recipient of 15% (Private Sale)
     * @param _publicSale Recipient of 45% (Public Sale)
     *
     * Token Details:
     * - Name: "Fundtir"
     * - Symbol: "FNTR"
     * - Decimals: 18 (standard)
     * - Total Supply: 700,000,000 FNTR tokens
     * - Distribution: 10/15/15/15/45 to the provided allocation addresses
     */
    constructor(
        address _adminWallet,
        address _marketingRewards,
        address _reserveOperations,
        address _foundingTeam,
        address _privateSale,
        address _publicSale
    )
        ERC20("Fundtir", "FNTR")
        ERC20Permit("Fundtir")
        Ownable(_adminWallet)
    {
        uint256 totalSupply = 700_000_000 * 10**decimals(); // 700 Million supply
        // Allocation distribution (must sum to 100%)
        // Marketing & Rewards: 10%
        // Reserve / Operations: 15%
        // Founding Team: 15%
        // Private Sale: 15%
        // Public Sale: 45%

        uint256 marketingRewardsAmount = (totalSupply * 10) / 100;
        uint256 reserveOperationsAmount = (totalSupply * 15) / 100;
        uint256 foundingTeamAmount = (totalSupply * 15) / 100;
        uint256 privateSaleAmount = (totalSupply * 15) / 100;
        uint256 publicSaleAmount = totalSupply - (
            marketingRewardsAmount +
            reserveOperationsAmount +
            foundingTeamAmount +
            privateSaleAmount
        );

        _mint(_marketingRewards, marketingRewardsAmount);
        _mint(_reserveOperations, reserveOperationsAmount);
        _mint(_foundingTeam, foundingTeamAmount);
        _mint(_privateSale, privateSaleAmount);
        _mint(_publicSale, publicSaleAmount);
    }
}