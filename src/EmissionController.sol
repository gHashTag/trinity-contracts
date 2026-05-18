// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

/**
 * @title EmissionController
 * @notice Pure-math library contract for TRI emission curve calculations.
 *
 *         The emission schedule uses a halving model: each era lasts
 *         HALVING_PERIOD seconds, and the base reward halves every era
 *         starting from ERA_0_REWARD (1000 TRI).  Eras 0–9 are explicitly
 *         supported; era 10+ yields zero reward (all supply has been
 *         distributed).
 *
 *         GENESIS_TIMESTAMP must be set at deployment time by subclassing
 *         or by deploying a concrete version of this contract.
 */
contract EmissionController {

    // ─────────────────────────────────────────────────────────────────────────
    // Time constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Duration of a single emission era (4 Gregorian years in seconds).
    uint256 public constant HALVING_PERIOD = 4 * 365 days;

    /// @notice Base reward for Era 0 (1 000 TRI, 18 decimals).
    uint256 public constant ERA_0_REWARD = 1_000 * 10 ** 18;

    /// @notice Number of supported eras (0 inclusive through MAX_ERA inclusive).
    uint8   public constant MAX_ERA = 9;

    // ─────────────────────────────────────────────────────────────────────────
    // Deployment anchor
    // ─────────────────────────────────────────────────────────────────────────

    // SET AT DEPLOYMENT
    uint256 public immutable GENESIS_TIMESTAMP;

    constructor(uint256 genesisTimestamp) {
        require(genesisTimestamp > 0, "EmissionController: zero genesis");
        GENESIS_TIMESTAMP = genesisTimestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Era queries
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Return the Unix timestamp at which `era` begins.
     * @param era Era index (0-based).
     * @return startTs Unix timestamp of the era boundary.
     */
    function eraStart(uint8 era) public view returns (uint256 startTs) {
        startTs = GENESIS_TIMESTAMP + uint256(era) * HALVING_PERIOD;
    }

    /**
     * @notice Return the Unix timestamp at which `era` ends (i.e., era+1 begins).
     * @param era Era index (0-based).
     * @return endTs Unix timestamp of the era end boundary.
     */
    function eraEnd(uint8 era) public view returns (uint256 endTs) {
        endTs = eraStart(era) + HALVING_PERIOD;
    }

    /**
     * @notice Compute the per-claim base reward for `era` (halvings applied).
     *         Era 0 → 1 000 TRI, Era 1 → 500 TRI, …, Era 9 → ~1.953 TRI.
     *         Returns 0 for era > MAX_ERA.
     *
     * @param era Era index (0-based).
     * @return reward Per-claim reward in TRI wei.
     */
    function rewardForEra(uint8 era) public pure returns (uint256 reward) {
        if (era > MAX_ERA) return 0;
        // Arithmetic right-shift by `era` is equivalent to dividing by 2^era.
        reward = ERA_0_REWARD >> era;
    }

    /**
     * @notice Compute the cumulative TRI supply released through the *end* of
     *         `era` (i.e., sum of rewards for eras 0..era).
     *
     *         Uses the geometric-series identity:
     *             S = ERA_0_REWARD * (2 - 2^(-(era+1)))
     *               = ERA_0_REWARD * (1 - 1/2^(era+1)) * 2
     *
     *         In integer arithmetic:
     *             S = ERA_0_REWARD * (2^(era+1) - 1) / 2^era
     *
     *         Note: this is the reward-per-claim sum, not an absolute supply
     *         cap — actual supply released depends on the number of claims
     *         made in each era.
     *
     * @param era Era index (0-based).
     * @return cumulative Sum of rewardForEra(0) + … + rewardForEra(era).
     */
    function supplyReleasedByEra(uint8 era) public pure returns (uint256 cumulative) {
        // Sum = ERA_0 * (1 + 1/2 + 1/4 + … + 1/2^era)
        //     = ERA_0 * (2^(era+1) - 1) / 2^era
        uint256 n = uint256(era) + 1;          // era+1
        uint256 numerator   = (1 << n) - 1;   // 2^(era+1) - 1
        uint256 denominator = 1 << era;         // 2^era
        cumulative = ERA_0_REWARD * numerator / denominator;
    }

    /**
     * @notice Derive the current era from block.timestamp and GENESIS_TIMESTAMP.
     * @return era The current emission era index.
     */
    function currentEra() public view returns (uint8 era) {
        if (block.timestamp < GENESIS_TIMESTAMP) return 0;
        uint256 elapsed = block.timestamp - GENESIS_TIMESTAMP;
        uint256 e = elapsed / HALVING_PERIOD;
        era = e > MAX_ERA ? MAX_ERA : uint8(e);
    }
}
