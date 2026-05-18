// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

/**
 * @title JobProver
 * @notice On-chain Groth16 verifier wrapper for the B5 ZK Job Proof
 *         circuit. Uses Ethereum precompile 0x08 (BN254 pairing) plus
 *         0x07 (BN254 G1 scalar multiplication) and 0x06 (BN254 G1 add).
 *
 *         This contract is the bridge between off-chain Trinity chip
 *         compute (silicon emits chip signatures + champion BPB score)
 *         and the on-chain MiningPool.claim() entrypoint.
 *
 *         Public inputs of the B5 circuit (committed in the proof):
 *           [0] jobInputHash    (uint256, low half of SHA-256)
 *           [1] jobOutputHash   (uint256, low half of SHA-256)
 *           [2] chipPubkey      (uint256, derived from PUF)
 *           [3] bpbScoreX10000  (uint256, must be ≤ CHAMPION_BPB = 22393)
 *           [4] era             (uint256, must equal current era)
 *
 * @dev The verifyKey embedded below is a PLACEHOLDER for Sepolia testnet
 *      bring-up. Production deployment will regenerate it from the final
 *      circom artefacts and commit the new constants alongside a Zenodo
 *      DOI of the trusted-setup ceremony transcript.
 */
contract JobProver {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Champion BPB ceiling (2.2393 × 10 000). Proofs whose
    ///         claimed BPB score exceeds this are rejected even before
    ///         pairing — short-circuit defence against malformed inputs.
    uint256 public constant CHAMPION_BPB = 22_393;

    /// @notice Number of public inputs in the B5 circuit.
    uint256 public constant NUM_PUBLIC_INPUTS = 5;

    // ─────────────────────────────────────────────────────────────────────────
    // Groth16 verifying key (PLACEHOLDER — Sepolia bring-up only)
    // ─────────────────────────────────────────────────────────────────────────

    // alpha1
    uint256 internal constant ALPHA_X = 0x1;
    uint256 internal constant ALPHA_Y = 0x2;

    // beta2 (G2)
    uint256 internal constant BETA_X1 = 0x1;
    uint256 internal constant BETA_X2 = 0x0;
    uint256 internal constant BETA_Y1 = 0x1;
    uint256 internal constant BETA_Y2 = 0x0;

    // gamma2 (G2)
    uint256 internal constant GAMMA_X1 = 0x1;
    uint256 internal constant GAMMA_X2 = 0x0;
    uint256 internal constant GAMMA_Y1 = 0x1;
    uint256 internal constant GAMMA_Y2 = 0x0;

    // delta2 (G2)
    uint256 internal constant DELTA_X1 = 0x1;
    uint256 internal constant DELTA_X2 = 0x0;
    uint256 internal constant DELTA_Y1 = 0x1;
    uint256 internal constant DELTA_Y2 = 0x0;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidProof();
    error InvalidPublicInputs();
    error BpbAboveChampion();

    // ─────────────────────────────────────────────────────────────────────────
    // Verification entrypoint
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Verify a Groth16 proof of B5 ZK Job execution.
     * @param a            Proof element A (G1 point as [x, y]).
     * @param b            Proof element B (G2 point as [[x1,x2], [y1,y2]]).
     * @param c            Proof element C (G1 point as [x, y]).
     * @param publicInputs Array of 5 public inputs in canonical order.
     * @return ok          True iff proof is valid AND BPB score is below
     *                     champion threshold.
     *
     * @dev This MVP build returns `true` for any well-formed input shape
     *      while the trusted-setup ceremony is being finalised. The
     *      placeholder verifier MUST be replaced before Genesis Day. See
     *      docs/zk/verifier_outline.sol in the NeuronConstant repo for
     *      the production verifier scaffold.
     */
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicInputs
    ) external pure returns (bool ok) {
        if (publicInputs.length != NUM_PUBLIC_INPUTS) revert InvalidPublicInputs();

        // Short-circuit: BPB above champion is rejected before pairing.
        uint256 bpb = publicInputs[3];
        if (bpb > CHAMPION_BPB) revert BpbAboveChampion();

        // Basic well-formedness checks — full Groth16 pairing is
        // scaffolded but the verifying key above is a placeholder.
        // Suppress unused-variable warnings without state writes:
        a; b; c;

        // TODO: replace with full pairing call to precompile 0x08.
        return true;
    }
}
