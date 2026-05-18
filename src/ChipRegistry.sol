// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

/**
 * @title ChipRegistry
 * @notice Registry of physical Trinity SKY26b chips (Phi, Euler, Gamma).
 *         Each chip is identified by a public key derived from its
 *         on-die PUF (Physical Unclonable Function). The registry binds
 *         the chip family (1=Phi, 2=Euler, 3=Gamma), a phi-anchor
 *         invariant (must equal 0x47C0), and slashing/active state.
 *
 *         Used by MiningPool to verify that a chip submitting a proof is
 *         a real, registered, non-slashed Trinity die.
 *
 * @dev Registration is permissionless after deployment (no privileged
 *      role): anyone who can demonstrate a valid PUF fingerprint via an
 *      off-chain signature wrapping the chip's bootstrap challenge can
 *      register their die. The off-chain signature scheme is verified
 *      against the chip's published `attestor` public key in a separate
 *      attestor contract; this minimal registry exposes only the
 *      surface MiningPool depends on.
 */
contract ChipRegistry {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Canonical phi-anchor (TG-TRIAD-X Theorem 36.1). All real
    ///         Trinity chips drive this constant on {uio_out, uo_out} at
    ///         reset and expose it via the on-die champion_bpb_oracle.
    uint16 public constant PHI_ANCHOR = 0x47C0;

    /// @notice Chip family enumeration.
    uint8 public constant FAMILY_PHI   = 1;
    uint8 public constant FAMILY_EULER = 2;
    uint8 public constant FAMILY_GAMMA = 3;

    // ─────────────────────────────────────────────────────────────────────────
    // Chip record
    // ─────────────────────────────────────────────────────────────────────────

    struct ChipRecord {
        uint8   family;        // 1=Phi, 2=Euler, 3=Gamma
        uint16  phiAnchor;     // must equal PHI_ANCHOR
        uint32  registeredAt;  // block.timestamp truncated
        bool    slashed;       // true if chip was caught cheating
        address attestor;      // owner / authorized claimer
    }

    /// @dev chipPubkey -> record
    mapping(bytes32 => ChipRecord) private _chips;

    /// @notice Total registered chips per family.
    mapping(uint8 => uint256) public chipCountByFamily;

    /// @notice Total registered chips (all families).
    uint256 public totalChips;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ChipRegistered(bytes32 indexed chipPubkey, uint8 family, address attestor);
    event ChipSlashed(bytes32 indexed chipPubkey, string reason);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroPubkey();
    error AlreadyRegistered();
    error InvalidFamily();
    error PhiAnchorMismatch();
    error ChipNotFound();
    error AlreadySlashed();
    error NotAttestor();

    // ─────────────────────────────────────────────────────────────────────────
    // Registration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Register a Trinity chip.
     * @param chipPubkey   Unique chip identifier (derived from PUF).
     * @param family       1=Phi, 2=Euler, 3=Gamma.
     * @param phiAnchorOut Anchor constant the chip drives on its outputs.
     *                     Must equal `PHI_ANCHOR` (0x47C0).
     *
     * @dev `msg.sender` becomes the attestor and is the only address that
     *      can later slash this chip. In production, this call would be
     *      gated by an off-chain PUF challenge/response signature; this
     *      MVP exposes the gate-free path for Sepolia testnet.
     */
    function registerChip(
        bytes32 chipPubkey,
        uint8   family,
        uint16  phiAnchorOut
    ) external {
        if (chipPubkey == bytes32(0))                     revert ZeroPubkey();
        if (_chips[chipPubkey].registeredAt != 0)          revert AlreadyRegistered();
        if (family < FAMILY_PHI || family > FAMILY_GAMMA)  revert InvalidFamily();
        if (phiAnchorOut != PHI_ANCHOR)                    revert PhiAnchorMismatch();

        _chips[chipPubkey] = ChipRecord({
            family:       family,
            phiAnchor:    phiAnchorOut,
            registeredAt: uint32(block.timestamp),
            slashed:      false,
            attestor:     msg.sender
        });

        chipCountByFamily[family] += 1;
        totalChips += 1;

        emit ChipRegistered(chipPubkey, family, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slashing
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Mark a chip as slashed (caught cheating). Only the chip's
     *         original attestor may slash it. Slashed chips lose the
     *         ability to claim future rewards.
     */
    function slashChip(bytes32 chipPubkey, string calldata reason) external {
        ChipRecord storage r = _chips[chipPubkey];
        if (r.registeredAt == 0) revert ChipNotFound();
        if (r.slashed)           revert AlreadySlashed();
        if (msg.sender != r.attestor) revert NotAttestor();

        r.slashed = true;
        emit ChipSlashed(chipPubkey, reason);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice MiningPool interface — true if chip is registered AND not slashed.
    function isRegistered(bytes32 chipPubkey) external view returns (bool) {
        ChipRecord storage r = _chips[chipPubkey];
        return r.registeredAt != 0 && !r.slashed;
    }

    function chipInfo(bytes32 chipPubkey)
        external
        view
        returns (
            uint8   family,
            uint16  phiAnchor,
            uint32  registeredAt,
            bool    slashed,
            address attestor
        )
    {
        ChipRecord storage r = _chips[chipPubkey];
        return (r.family, r.phiAnchor, r.registeredAt, r.slashed, r.attestor);
    }
}
