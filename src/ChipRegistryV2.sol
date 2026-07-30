// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ChipRegistryV2
 * @notice Registration gate for the chip registry, for a future deployment.
 *
 *         The deployed ChipRegistry accepts any caller with any 32-byte value,
 *         subject only to a check against a constant published in the contract
 *         itself. Its own documentation says so - it exposes the gate-free path
 *         deliberately, for testnet bring-up - and MiningPool's registration
 *         check therefore establishes that a registration transaction happened
 *         rather than that hardware exists. This contract closes that.
 *
 *         It cannot be retrofitted to the current deployment: MiningPool's
 *         ownership was renounced at deployment, so the registry it consults can
 *         never be replaced. This targets the next one.
 *
 * @dev What the gate proves, and what it does not.
 *
 *      Proves: whoever registered a chip identifier held the private key that
 *      identifier is derived from, at the time of registration, for this
 *      registry, on this chain, once.
 *
 *      Does not prove: that the key lives on a die rather than in a file. No
 *      on-chain check can establish that. Establishing it needs a challenge the
 *      hardware answers under a constraint software cannot meet, which is a
 *      separate problem and is recorded as partially solved at best - a timing
 *      deadline was tested and refuted, and a parallel-width challenge holds
 *      against a general-purpose processor and fails against a many-lane
 *      accelerator.
 *
 *      So this raises the floor from "anyone may claim to be any chip" to "only
 *      the holder of a chip's key may register that chip". That is the whole
 *      claim being made here.
 *
 * @dev Identifier scheme. The chip identifier is the chip's own address, left
 *      zero-padded into a bytes32. This makes the identifier self-authenticating:
 *      a signature recovers to an address, and the identifier being registered
 *      must be that address. The alternative - an arbitrary 32-byte value plus a
 *      separate signing address - lets anyone bind any identifier to a key they
 *      hold, which reintroduces the problem the gate exists to solve.
 */
contract ChipRegistryV2 {

    using ECDSA for bytes32;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Canonical phi-anchor. Retained from the deployed registry, but
    ///         demoted in meaning: it is a format assertion, not a gate. A
    ///         constant published in this contract cannot gate anything, since
    ///         anyone who can read the contract can supply it.
    uint16 public constant PHI_ANCHOR = 0x47C0;

    uint8 public constant FAMILY_PHI   = 1;
    uint8 public constant FAMILY_EULER = 2;
    uint8 public constant FAMILY_GAMMA = 3;

    /// @notice Domain tag, so a signature for this purpose cannot be reused for
    ///         another one that happens to hash the same fields.
    string public constant REGISTER_DOMAIN = "trinity-chip-registration-v2";

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    struct ChipRecord {
        uint8   family;
        uint16  phiAnchor;
        uint32  registeredAt;
        bool    slashed;
        address attestor;
    }

    mapping(bytes32 => ChipRecord) private _chips;

    /// @notice Consumed registration nonces, per chip. A nonce is scoped to the
    ///         chip rather than global so that concurrent registrations of
    ///         different chips cannot invalidate each other.
    mapping(bytes32 => mapping(uint256 => bool)) public nonceUsed;

    mapping(uint8 => uint256) public chipCountByFamily;
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
    error NonceAlreadyUsed();
    error SignatureNotFromChip();
    error IdentifierNotAnAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Registration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice The message a chip must sign in order to be registered.
     *
     *         Four bindings, each closing a distinct replay:
     *
     *           chipPubkey   the identity being claimed
     *           registrant   the address submitting the transaction, so a
     *                        captured signature cannot be submitted by a third
     *                        party
     *           address(this) this registry, so it cannot be replayed onto
     *                        another deployment
     *           block.chainid this chain, so it cannot be replayed onto a fork
     *                        or another network
     *           nonce        once, so it cannot be replayed here
     */
    function registrationDigest(
        bytes32 chipPubkey,
        address registrant,
        uint256 nonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(REGISTER_DOMAIN)),
                chipPubkey,
                registrant,
                address(this),
                block.chainid,
                nonce
            )
        );
        return MessageHashUtils.toEthSignedMessageHash(structHash);
    }

    /**
     * @notice Register a chip, proving possession of its key.
     * @param chipPubkey   The chip's address, left zero-padded into bytes32.
     * @param family       1=Phi, 2=Euler, 3=Gamma.
     * @param phiAnchorOut Format assertion; must equal PHI_ANCHOR.
     * @param nonce        Registration nonce, consumed on success.
     * @param signature    Signature by the chip over registrationDigest.
     */
    function registerChip(
        bytes32 chipPubkey,
        uint8   family,
        uint16  phiAnchorOut,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (chipPubkey == bytes32(0))                      revert ZeroPubkey();
        if (_chips[chipPubkey].registeredAt != 0)          revert AlreadyRegistered();
        if (family < FAMILY_PHI || family > FAMILY_GAMMA)  revert InvalidFamily();
        if (phiAnchorOut != PHI_ANCHOR)                    revert PhiAnchorMismatch();
        if (nonceUsed[chipPubkey][nonce])                  revert NonceAlreadyUsed();

        // The identifier must be an address in the low 160 bits and nothing in
        // the high 96, or it cannot be the address a signature recovers to.
        if (uint256(chipPubkey) >> 160 != 0)               revert IdentifierNotAnAddress();

        address recovered = ECDSA.recover(
            registrationDigest(chipPubkey, msg.sender, nonce),
            signature
        );
        if (recovered != address(uint160(uint256(chipPubkey)))) revert SignatureNotFromChip();

        nonceUsed[chipPubkey][nonce] = true;

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
    // Slashing — unchanged from the deployed registry
    // ─────────────────────────────────────────────────────────────────────────

    function slashChip(bytes32 chipPubkey, string calldata reason) external {
        ChipRecord storage r = _chips[chipPubkey];
        if (r.registeredAt == 0)      revert ChipNotFound();
        if (r.slashed)                revert AlreadySlashed();
        if (msg.sender != r.attestor) revert NotAttestor();

        r.slashed = true;
        emit ChipSlashed(chipPubkey, reason);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views — same surface MiningPool depends on
    // ─────────────────────────────────────────────────────────────────────────

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
