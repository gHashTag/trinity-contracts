// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./EmissionController.sol";

/**
 * @title MiningPool
 * @notice Holds 100 % of the TRI supply and distributes it through
 *         verifiable chip ZK proof claims.
 *
 *         Architecture overview
 *         ─────────────────────
 *         • 27 bank registers (t0–t26) each have an individual allocation cap
 *           drawn from the global TOTAL_SUPPLY.
 *         • Claimants submit a proof_type (register index), opaque proof_data,
 *           a chip_signature, and the current era.  The contract verifies the
 *           chip is registered, records the claim, and transfers TRI.
 *         • Rewards halve each era (see EmissionController).
 *         • Double-claim prevention: a nullifier hash over
 *           (chip_id, era, proof_data) is stored permanently.
 */

/// @dev Minimal ERC20 interface needed by MiningPool.
interface ITRI {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal chip registry interface.
interface IChipRegistry {
    /// @notice Returns true if `pubkey` is a registered Trinity chip.
    function isRegistered(bytes32 pubkey) external view returns (bool);
}

contract MiningPool is Ownable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────────────────
    // Proof types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice B5 ZK Job Prover (register t0).
    uint8 public constant PROOF_B5_ZK_JOB         = 0;
    /// @notice B9 Bittensor Validator (register t3).
    uint8 public constant PROOF_B9_BITTENSOR       = 3;
    /// @notice Generic proof type ceiling — registers 0–26 are valid.
    uint8 public constant MAX_REGISTER             = 26;

    // ─────────────────────────────────────────────────────────────────────────
    // Supply constants  (per-register allocation caps, in TRI wei)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total supply in TRI wei (3^27 × 10^18).
    uint256 public constant TOTAL_SUPPLY = 7_625_597_484_987 * 10 ** 18;

    // ─────────────────────────────────────────────────────────────────────────
    // Genesis / era timing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Unix timestamp at which Era 0 began. SET AT DEPLOYMENT.
    uint256 public immutable GENESIS;

    /// @notice Duration of one era in seconds (4 years).
    uint256 public constant ERA_PERIOD = 4 * 365 days;

    /// @notice Maximum era index (inclusive).
    uint8   public constant MAX_ERA    = 9;

    // ─────────────────────────────────────────────────────────────────────────
    // Reward table (Era 0..9), mirroring EmissionController
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant ERA_0_REWARD = 1_000 * 10 ** 18;

    // ─────────────────────────────────────────────────────────────────────────
    // Per-register allocation caps
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Mapping: register index → allocation cap (TRI wei).
    mapping(uint8 => uint256) private _registerCap;

    /// @dev Mapping: register index → total TRI claimed so far.
    mapping(uint8 => uint256) private _registerClaimed;

    // ─────────────────────────────────────────────────────────────────────────
    // External contracts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The TRI ERC20 token contract.
    ITRI public immutable triToken;

    /// @notice Registry of valid Trinity chip public keys.
    IChipRegistry public chipRegistry;

    // ─────────────────────────────────────────────────────────────────────────
    // Nullifier tracking (double-claim prevention)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev nullifier → already used.
    mapping(bytes32 => bool) private _nullifiers;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted on every successful proof claim.
     * @param claimer       Address that receives the TRI reward.
     * @param register      Bank register index (0–26) for the proof type.
     * @param era           Emission era at the time of the claim.
     * @param rewardAmount  TRI wei transferred to claimer.
     * @param chipId        Chip public key that signed the proof.
     */
    event ProofClaimed(
        address indexed claimer,
        uint8   indexed register,
        uint8           era,
        uint256         rewardAmount,
        bytes32 indexed chipId
    );

    /// @notice Emitted when the chip registry is updated by the owner.
    event ChipRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _triToken      Address of the deployed TriToken contract.
     * @param _chipRegistry  Address of the initial chip registry.
     * @param _genesis       Unix timestamp for Era 0 start.
     */
    constructor(
        address _triToken,
        address _chipRegistry,
        uint256 _genesis
    )
        Ownable(msg.sender)
    {
        require(_triToken      != address(0), "MiningPool: zero token");
        require(_chipRegistry  != address(0), "MiningPool: zero registry");
        require(_genesis        > 0,          "MiningPool: zero genesis");

        triToken     = ITRI(_triToken);
        chipRegistry = IChipRegistry(_chipRegistry);
        GENESIS      = _genesis;

        // ── Initialise per-register allocation caps ───────────────────────
        // Caps are based on the Trinity kernel register significance weights.
        // Total across all 27 registers must equal TOTAL_SUPPLY.
        //
        // Anchors specified in the spec; remaining registers share the residual
        // proportionally.  Values below are illustrative anchors — adjust to
        // the final tokenomics sheet before deployment.

        _registerCap[0]  = 1_906_399_371_247 * 10 ** 18; // t0  B5 ZK Job Prover
        _registerCap[1]  =   953_199_685_624 * 10 ** 18; // t1
        _registerCap[2]  =   476_599_842_812 * 10 ** 18; // t2
        _registerCap[3]  =   762_559_748_499 * 10 ** 18; // t3  B9 Bittensor Validator
        _registerCap[4]  =   381_279_874_250 * 10 ** 18; // t4
        _registerCap[5]  =   381_279_874_250 * 10 ** 18; // t5
        _registerCap[6]  =   381_279_874_250 * 10 ** 18; // t6
        _registerCap[7]  =   190_639_937_125 * 10 ** 18; // t7
        _registerCap[8]  =   190_639_937_125 * 10 ** 18; // t8
        _registerCap[9]  =   190_639_937_125 * 10 ** 18; // t9
        _registerCap[10] =   190_639_937_125 * 10 ** 18; // t10
        _registerCap[11] =   190_639_937_125 * 10 ** 18; // t11
        _registerCap[12] =   190_639_937_125 * 10 ** 18; // t12
        _registerCap[13] =   190_639_937_125 * 10 ** 18; // t13
        _registerCap[14] =   190_639_937_125 * 10 ** 18; // t14
        _registerCap[15] =   190_639_937_125 * 10 ** 18; // t15
        _registerCap[16] =    95_319_968_563 * 10 ** 18; // t16
        _registerCap[17] =    95_319_968_563 * 10 ** 18; // t17
        _registerCap[18] =    95_319_968_563 * 10 ** 18; // t18
        _registerCap[19] =    95_319_968_563 * 10 ** 18; // t19
        _registerCap[20] =    95_319_968_563 * 10 ** 18; // t20
        _registerCap[21] =    95_319_968_563 * 10 ** 18; // t21
        _registerCap[22] =    95_319_968_563 * 10 ** 18; // t22
        _registerCap[23] =    95_319_968_563 * 10 ** 18; // t23
        _registerCap[24] =    95_319_968_563 * 10 ** 18; // t24
        _registerCap[25] =    95_319_968_563 * 10 ** 18; // t25
        _registerCap[26] =    95_319_968_563 * 10 ** 18; // t26
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Replace the chip registry (owner-only).
     * @param newRegistry New registry address.
     */
    function setChipRegistry(address newRegistry) external onlyOwner {
        require(newRegistry != address(0), "MiningPool: zero registry");
        emit ChipRegistryUpdated(address(chipRegistry), newRegistry);
        chipRegistry = IChipRegistry(newRegistry);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Era helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Derive the emission era from block.timestamp.
     * @return era Current era index (clamped to MAX_ERA).
     */
    function getEra() public view returns (uint8 era) {
        if (block.timestamp < GENESIS) return 0;
        uint256 elapsed = block.timestamp - GENESIS;
        uint256 e = elapsed / ERA_PERIOD;
        era = e > MAX_ERA ? MAX_ERA : uint8(e);
    }

    /**
     * @notice Base reward for a given `era` (halving schedule).
     * @param era Era index.
     * @return reward Per-claim reward in TRI wei.
     */
    function rewardForEra(uint8 era) public pure returns (uint256 reward) {
        if (era > MAX_ERA) return 0;
        reward = ERA_0_REWARD >> era;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Register queries
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Total allocation cap for `register`.
     * @param register Bank register index (0–26).
     * @return cap Allocation cap in TRI wei.
     */
    function getCapForRegister(uint8 register) external view returns (uint256 cap) {
        require(register <= MAX_REGISTER, "MiningPool: invalid register");
        cap = _registerCap[register];
    }

    /**
     * @notice Remaining claimable TRI for `register`.
     * @param register Bank register index (0–26).
     * @return remaining TRI wei still available in this register's allocation.
     */
    function getRemainingForRegister(uint8 register) external view returns (uint256 remaining) {
        require(register <= MAX_REGISTER, "MiningPool: invalid register");
        uint256 cap     = _registerCap[register];
        uint256 claimed = _registerClaimed[register];
        remaining = cap > claimed ? cap - claimed : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core claim logic
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Submit a chip ZK proof and receive a TRI reward.
     *
     * @param proof_type      Bank register index (0–26) identifying the work type.
     * @param proof_data      Opaque ZK proof payload (verified off-chain or via
     *                        on-chain verifier; this contract records it for
     *                        nullifier derivation).
     * @param chip_signature  ECDSA or Schnorr signature from the Trinity chip,
     *                        signing keccak256(abi.encodePacked(proof_data, era)).
     * @param era             Declared era — must match the current on-chain era.
     */
    function claim(
        uint8   proof_type,
        bytes   calldata proof_data,
        bytes   calldata chip_signature,
        uint8   era
    )
        external
        nonReentrant
    {
        // ── 1. Validate inputs ────────────────────────────────────────────
        require(proof_type <= MAX_REGISTER,     "MiningPool: invalid proof type");
        require(proof_data.length > 0,          "MiningPool: empty proof");
        require(chip_signature.length == 65,    "MiningPool: bad signature length");

        // ── 2. Era check ──────────────────────────────────────────────────
        uint8 currentEra = getEra();
        require(era == currentEra, "MiningPool: era mismatch");

        // ── 3. Recover chip public key from signature ─────────────────────
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(proof_data, era))
            )
        );
        bytes32 chipId = _recoverChipId(messageHash, chip_signature);

        // ── 4. Verify chip is registered ──────────────────────────────────
        require(chipRegistry.isRegistered(chipId), "MiningPool: unregistered chip");

        // ── 5. Nullifier check (prevent double-claim) ─────────────────────
        bytes32 nullifier = keccak256(abi.encodePacked(chipId, era, proof_data));
        require(!_nullifiers[nullifier], "MiningPool: already claimed");
        _nullifiers[nullifier] = true;

        // ── 6. Compute reward ─────────────────────────────────────────────
        uint256 reward = rewardForEra(era);
        require(reward > 0, "MiningPool: zero reward");

        // ── 7. Register allocation check ─────────────────────────────────
        uint256 remaining = _registerCap[proof_type] - _registerClaimed[proof_type];
        require(remaining >= reward, "MiningPool: register cap exhausted");
        _registerClaimed[proof_type] += reward;

        // ── 8. Transfer TRI to claimant ───────────────────────────────────
        require(
            triToken.transfer(msg.sender, reward),
            "MiningPool: transfer failed"
        );

        emit ProofClaimed(msg.sender, proof_type, era, reward, chipId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Recover the bytes32 chip ID (public key hash) from a 65-byte
     *      Ethereum ECDSA signature.  Returns the signer address cast to
     *      bytes32 as a chip identifier.
     */
    function _recoverChipId(bytes32 msgHash, bytes calldata sig)
        internal
        pure
        returns (bytes32 chipId)
    {
        require(sig.length == 65, "MiningPool: sig length");
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        address signer = ecrecover(msgHash, v, r, s);
        require(signer != address(0), "MiningPool: invalid signature");
        chipId = bytes32(uint256(uint160(signer)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rescue (owner-only, for non-TRI tokens accidentally sent to this contract)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Rescue any ERC20 token *other than* TRI sent here by mistake.
     * @param token   Token contract address.
     * @param to      Recipient.
     * @param amount  Amount to rescue.
     */
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyOwner
    {
        require(token != address(triToken), "MiningPool: cannot rescue TRI");
        (bool ok, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok, "MiningPool: rescue failed");
    }
}
