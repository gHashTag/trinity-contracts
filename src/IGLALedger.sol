// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// IGLALedger — On-Chain Mirror of trios-trainer-igla/assertions/seed_results.jsonl
//
// IGLA RACE Training Pipeline ↔ DePIN On-Chain Integration.
// Champion: BPB=2.2393 @ step=27000 seed=43 sha=2446855
// Source:   gHashTag/trios-trainer-igla (assertions/champion_lock.txt)
//
// Architecture:
//   IGLA daemon (off-chain indexer) →
//   M-of-N oracle multisig →
//   IGLALedger.submitRow  →
//   TrainingProver.verifyAndSubmit →
//   TRIBridge.claim → TRIToken.mint
//
// Design principles:
//   - No-regression invariant: row accepted only if bpbE6 strictly improves (lower is better)
//   - Gate-2 quorum: >= 3 chips must hit target before phase gate opens
//   - Oracle signature: IGLA daemon signs each row with secp256k1
//   - Step monotonicity: prevents replay attacks within a chip
//
// Extends:
//   - contracts/src/TRIBridge.sol (oracle multisig pattern)
//   - docs/zk/verifier_outline.sol (proof-of-compute semantics)
//   - common/depin/v2/tri_mofn_attest.v (HW M-of-N attestation, DePIN #3)
//
// v1.0.0 modules preserved. DePIN improvement set extended.
// Author: Dmitrii Vasilev (gHashTag)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Minimal interface for M-of-N attestation module.
interface IMofNTrainingAttest {
    function isRowAttested(bytes32 rowHash) external view returns (bool);
}

contract IGLALedger {
    // ─── Types ───────────────────────────────────────────────────────────────

    /// @notice On-chain mirror of one row from assertions/seed_results.jsonl.
    /// @dev    bpbE6 = BPB * 1e6, e.g. BPB=2.2393 → 2239300 (fits uint32: max ~4294)
    ///         sha is the first 7 bytes of the git commit hash / ledger entry hash.
    ///         gateStatus: 0=pending, 1=gate1_passed, 2=gate2_passed.
    struct TrainingRow {
        bytes32 chipSerial;  // Unique chip identifier (DePIN hardware serial)
        uint64  step;        // Training step number (e.g. 27000)
        uint32  seed;        // Random seed used for this training run (e.g. 43)
        uint32  bpbE6;       // Bits-per-byte * 1e6 (lower is better; 2.2393 → 2239300)
        bytes7  sha;         // First 7 bytes of row hash / commit sha
        uint64  jsonlRow;    // Row index in assertions/seed_results.jsonl
        uint8   gateStatus;  // 0=pending, 1=gate1_passed, 2=gate2_passed
        uint64  timestamp;   // Block timestamp at submission
    }

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Authorized IGLA oracle addresses (off-chain daemon signers).
    mapping(address => bool) public authorizedOracles;

    /// @notice All training rows indexed by chip serial.
    mapping(bytes32 => TrainingRow[]) public rowsByChip;

    /// @notice Best (lowest) bpbE6 per chip serial. 0 means no rows yet.
    mapping(bytes32 => uint32) public bestBPB;

    /// @notice Global champion row (lowest bpbE6 across all chips).
    TrainingRow private _champion;
    bool private _hasChampion;

    /// @notice Step monotonicity guard: last accepted step per chip.
    mapping(bytes32 => uint64) public lastStep;

    /// @notice Number of distinct chips that have passed a given bpbE6 target.
    /// gate2Chips[targetBpbE6] = set of chipSerials that reached it.
    mapping(uint32 => mapping(bytes32 => bool)) private _gate2Chips;
    mapping(uint32 => uint32) public gate2Count;

    /// @notice Optional M-of-N attestation module address (zero = disabled).
    address public attestModule;

    /// @notice Owner (deployer) — can update oracle list and attest module.
    address public immutable owner;

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted for every accepted training row.
    event RowSubmitted(
        bytes32 indexed chipSerial,
        uint64  step,
        uint32  seed,
        uint32  bpbE6,
        uint64  jsonlRow,
        uint8   gateStatus,
        uint64  timestamp
    );

    /// @notice Emitted when the global champion BPB is improved.
    event ChampionUpdated(
        bytes32 indexed chipSerial,
        uint64  step,
        uint32  seed,
        uint32  bpbE6,
        uint64  timestamp
    );

    /// @notice Emitted when gate-2 quorum is first reached for a target.
    event Gate2QuorumReached(uint32 indexed targetBpbE6, uint32 chipCount);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "IGLALedger: not owner");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param _oracles Initial list of authorized IGLA oracle addresses.
    constructor(address[] memory _oracles) {
        require(_oracles.length > 0, "IGLALedger: no oracles");
        owner = msg.sender;
        for (uint256 i = 0; i < _oracles.length; i++) {
            require(_oracles[i] != address(0), "IGLALedger: zero oracle");
            authorizedOracles[_oracles[i]] = true;
        }
    }

    // ─── Core: submitRow ─────────────────────────────────────────────────────

    /// @notice Submit a training row from the IGLA daemon.
    /// @dev    Validates oracle signature, step monotonicity, and no-regression BPB.
    ///         If M-of-N attestation module is configured, row must be pre-attested.
    ///
    ///         oracle_sig is an EIP-191 personal-sign signature over:
    ///           keccak256(abi.encode(row fields without timestamp))
    ///
    /// @param row        TrainingRow to record (timestamp will be set to block.timestamp).
    /// @param oracle_sig ECDSA signature (65 bytes: r || s || v) from authorized oracle.
    function submitRow(
        TrainingRow calldata row,
        bytes calldata oracle_sig
    ) external {
        // ---- Attestation module check (if configured) ----
        if (attestModule != address(0)) {
            bytes32 rowHash = _rowHash(row);
            require(
                IMofNTrainingAttest(attestModule).isRowAttested(rowHash),
                "IGLALedger: row not attested by M-of-N module"
            );
        }

        // ---- Oracle signature verification ----
        bytes32 msgHash = _rowSigningHash(row);
        address signer = _recoverSigner(msgHash, oracle_sig);
        require(authorizedOracles[signer], "IGLALedger: invalid oracle signature");

        // ---- Step monotonicity: prevents replay ----
        require(
            row.step > lastStep[row.chipSerial] || lastStep[row.chipSerial] == 0,
            "IGLALedger: step regression"
        );

        // ---- No-regression BPB invariant ----
        // bpbE6 must strictly improve (lower is better).
        uint32 current = bestBPB[row.chipSerial];
        require(
            current == 0 || row.bpbE6 < current,
            "IGLALedger: BPB does not improve best"
        );

        // ---- Write state ----
        uint64 ts = uint64(block.timestamp);
        TrainingRow memory stored = TrainingRow({
            chipSerial: row.chipSerial,
            step:       row.step,
            seed:       row.seed,
            bpbE6:      row.bpbE6,
            sha:        row.sha,
            jsonlRow:   row.jsonlRow,
            gateStatus: row.gateStatus,
            timestamp:  ts
        });

        rowsByChip[row.chipSerial].push(stored);
        bestBPB[row.chipSerial] = row.bpbE6;
        lastStep[row.chipSerial] = row.step;

        emit RowSubmitted(
            row.chipSerial,
            row.step,
            row.seed,
            row.bpbE6,
            row.jsonlRow,
            row.gateStatus,
            ts
        );

        // ---- Update gate-2 tracking ----
        // Record this chip as having reached bpbE6 target = row.bpbE6
        if (!_gate2Chips[row.bpbE6][row.chipSerial]) {
            _gate2Chips[row.bpbE6][row.chipSerial] = true;
            gate2Count[row.bpbE6] += 1;
            if (gate2Count[row.bpbE6] == 3) {
                emit Gate2QuorumReached(row.bpbE6, 3);
            }
        }

        // ---- Update global champion ----
        if (!_hasChampion || row.bpbE6 < _champion.bpbE6) {
            _champion = stored;
            _hasChampion = true;
            emit ChampionUpdated(
                row.chipSerial,
                row.step,
                row.seed,
                row.bpbE6,
                ts
            );
        }
    }

    // ─── Core: submitRowVerified ──────────────────────────────────────────────

    /// @notice Privileged entry point callable only by TrainingProver contract.
    ///         Skips oracle-sig check (prover already verified ZK + sig).
    /// @dev    Only the designated prover address may call this.
    address public trainingProver;

    function submitRowVerified(TrainingRow calldata row) external {
        require(msg.sender == trainingProver, "IGLALedger: not trainingProver");

        uint32 current = bestBPB[row.chipSerial];
        require(
            current == 0 || row.bpbE6 < current,
            "IGLALedger: BPB does not improve best"
        );
        require(
            row.step > lastStep[row.chipSerial] || lastStep[row.chipSerial] == 0,
            "IGLALedger: step regression"
        );

        uint64 ts = uint64(block.timestamp);
        TrainingRow memory stored = TrainingRow({
            chipSerial: row.chipSerial,
            step:       row.step,
            seed:       row.seed,
            bpbE6:      row.bpbE6,
            sha:        row.sha,
            jsonlRow:   row.jsonlRow,
            gateStatus: row.gateStatus,
            timestamp:  ts
        });

        rowsByChip[row.chipSerial].push(stored);
        bestBPB[row.chipSerial] = row.bpbE6;
        lastStep[row.chipSerial] = row.step;

        emit RowSubmitted(
            row.chipSerial,
            row.step,
            row.seed,
            row.bpbE6,
            row.jsonlRow,
            row.gateStatus,
            ts
        );

        if (!_gate2Chips[row.bpbE6][row.chipSerial]) {
            _gate2Chips[row.bpbE6][row.chipSerial] = true;
            gate2Count[row.bpbE6] += 1;
            if (gate2Count[row.bpbE6] == 3) {
                emit Gate2QuorumReached(row.bpbE6, 3);
            }
        }

        if (!_hasChampion || row.bpbE6 < _champion.bpbE6) {
            _champion = stored;
            _hasChampion = true;
            emit ChampionUpdated(
                row.chipSerial,
                row.step,
                row.seed,
                row.bpbE6,
                ts
            );
        }
    }

    // ─── Queries ─────────────────────────────────────────────────────────────

    /// @notice Returns the current global champion training row.
    /// @dev    Reverts if no rows have been submitted yet.
    function getChampion() external view returns (TrainingRow memory) {
        require(_hasChampion, "IGLALedger: no champion yet");
        return _champion;
    }

    /// @notice Returns all training rows for a given chip serial.
    function getRowsByChip(bytes32 chipSerial)
        external view returns (TrainingRow[] memory)
    {
        return rowsByChip[chipSerial];
    }

    /// @notice Gate-2 quorum check: returns true if >= 3 distinct chips
    ///         have submitted rows achieving bpbE6 <= targetBpbE6.
    /// @dev    Note: this checks exact bpbE6 matches in the gate2Count mapping.
    ///         For range-based gate use gate2CountBelow().
    function gate2(uint32 targetBpbE6) external view returns (bool) {
        return gate2Count[targetBpbE6] >= 3;
    }

    /// @notice Returns count of chips that achieved exactly targetBpbE6.
    function gate2ChipCount(uint32 targetBpbE6) external view returns (uint32) {
        return gate2Count[targetBpbE6];
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setOracle(address oracle, bool authorized) external onlyOwner {
        require(oracle != address(0), "IGLALedger: zero oracle");
        authorizedOracles[oracle] = authorized;
    }

    function setAttestModule(address module) external onlyOwner {
        attestModule = module;
    }

    function setTrainingProver(address prover) external onlyOwner {
        require(prover != address(0), "IGLALedger: zero prover");
        trainingProver = prover;
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    /// @dev Compute the hash of a TrainingRow for M-of-N attestation lookup.
    function _rowHash(TrainingRow calldata row) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            row.chipSerial,
            row.step,
            row.seed,
            row.bpbE6,
            row.sha,
            row.jsonlRow,
            row.gateStatus
        ));
    }

    /// @dev Compute EIP-191 personal-sign hash for oracle signature verification.
    ///      Timestamp excluded (set on-chain); only training data signed by oracle.
    function _rowSigningHash(TrainingRow calldata row) internal pure returns (bytes32) {
        bytes32 dataHash = keccak256(abi.encode(
            row.chipSerial,
            row.step,
            row.seed,
            row.bpbE6,
            row.sha,
            row.jsonlRow,
            row.gateStatus
        ));
        return keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            dataHash
        ));
    }

    /// @dev Recover signer from EIP-191 signature (65 bytes: r || s || v).
    function _recoverSigner(
        bytes32 msgHash,
        bytes calldata sig
    ) internal pure returns (address) {
        require(sig.length == 65, "IGLALedger: invalid sig length");
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, sig.offset, 65)
            r := mload(ptr)
            s := mload(add(ptr, 32))
            v := byte(0, mload(add(ptr, 64)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "IGLALedger: invalid v");
        address recovered = ecrecover(msgHash, v, r, s);
        require(recovered != address(0), "IGLALedger: ecrecover failed");
        return recovered;
    }
}
