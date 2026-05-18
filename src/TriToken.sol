// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TriToken
 * @notice ERC20 token implementing 3^27 tokenomics.
 *         Total supply of 7,625,597,484,987 TRI is minted entirely to the
 *         MiningPool on deployment; ownership is immediately renounced so the
 *         supply can never be inflated.
 *
 * @dev Constants capture the mathematical/physical anchors of the Trinity
 *      kernel design:
 *        - TRINITY_KERNEL_STATES — state-space cardinality (3^27)
 *        - PHI_ANCHOR            — golden-ratio proximity marker (0x47C0)
 *        - CHAMPION_BPB          — champion bits-per-bit, scaled ×10 000
 *        - CHAMPION_STEP         — champion optimization step count
 *        - CHAMPION_SEED         — champion PRNG seed
 *        - CHAMPION_SHA          — champion SHA prefix
 */
contract TriToken is ERC20, ERC20Permit, ERC20Votes, Ownable {

    // ─────────────────────────────────────────────────────────────────────────
    // Supply constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total token supply (3^27 whole tokens, 18 decimals).
    uint256 public constant TOTAL_SUPPLY = 7_625_597_484_987 * 10 ** 18;

    /// @notice Cardinality of the Trinity kernel state-space (3^27).
    uint256 public constant TRINITY_KERNEL_STATES = 7_625_597_484_987;

    // ─────────────────────────────────────────────────────────────────────────
    // Trinity kernel calibration constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Golden-ratio proximity marker for the Trinity kernel.
    uint16  public constant PHI_ANCHOR     = 0x47C0;

    /// @notice Champion bits-per-bit, scaled by 10 000 (i.e., 2.2393 bpb).
    uint32  public constant CHAMPION_BPB   = 22_393;

    /// @notice Optimization step count of the champion solution.
    uint32  public constant CHAMPION_STEP  = 27_000;

    /// @notice PRNG seed used to derive the champion solution.
    uint8   public constant CHAMPION_SEED  = 43;

    /// @notice SHA prefix identifying the champion solution artefact.
    uint32  public constant CHAMPION_SHA   = 0x2446855;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when tokens are permanently destroyed via burn().
    event Burned(address indexed burner, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy TriToken, mint 100 % of supply to `miningPool`, then
     *         immediately renounce ownership so no further minting can ever
     *         occur via privileged calls.
     *
     * @param miningPool Address of the MiningPool contract that will hold
     *                   and distribute the entire supply via proof claims.
     */
    constructor(address miningPool)
        ERC20("TriToken", "TRI")
        ERC20Permit("TriToken")
        Ownable(msg.sender)
    {
        require(miningPool != address(0), "TriToken: zero mining pool");

        // Mint the full 3^27 supply to the mining pool — no pre-mine.
        _mint(miningPool, TOTAL_SUPPLY);

        // Renounce ownership immediately; no privileged functions remain.
        renounceOwnership();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Permanently destroy `amount` of the caller's own tokens.
     *         Reduces totalSupply irreversibly.
     *
     * @param amount Token amount to burn (in wei, i.e., × 10^18 per whole TRI).
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC20Votes / ERC20Permit overrides required by OpenZeppelin v5
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /// @inheritdoc ERC20Permit
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
