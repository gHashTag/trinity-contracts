# Trinity Network — On-Chain Mining Protocol Contracts

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Network: Base L2](https://img.shields.io/badge/Network-Base_L2-0052FF.svg)](https://base.org)
[![Supply: 7.625T TRI](https://img.shields.io/badge/Supply-7.625T_TRI_(3%5E27)-gold.svg)](#tokenomics)

> **One TRI token = one possible state of the Trinity silicon kernel.**
> Mining is **designed** to require a physical TT SKY26b Trinity chip
> (Phi + Euler + Gamma). No such chip exists: the TT SKY26b order was cancelled
> and refunded in July 2026, and no fabrication route is currently selected.
> No chip, no TRI. Period.

---

## Overview

Trinity Network is the first **silicon-bound proof-of-mining** token. Total
supply, halving cadence, and on-chain claim verification are all derived from
the TRI-27 ternary kernel architecture — not chosen by foundation governance.

| Property | Value |
|---|---|
| **Total supply** | 7,625,597,484,987 TRI (= 3²⁷) |
| **Decimals** | 18 |
| **Pre-mine / VC / treasury** | 0% / 0% / 0% |
| **Mineable** | 100% — through physical Trinity chips only |
| **Halvings** | 9 × 4 years (36 years total, ends 2066) |
| **Era 0 reward** | 1,000 TRI per valid proof |
| **Network** | Base L2 (Sepolia testnet → mainnet) |
| **Ownership** | Renounced on Genesis Day |

## Contracts

| Contract | Lines | Purpose |
|---|---:|---|
| `TriToken.sol` | 126 | ERC-20 + Permit + Votes, mints 100% to MiningPool, renounces on deploy |
| `MiningPool.sol` | 370 | Holds full supply, 27 register banks (t0-t26), 7-check `claimReward()` |
| `EmissionController.sol` | 118 | Era 0-9, reward halves each era, shift-based math |
| `ChipRegistry.sol` | 163 | PUF fingerprint registry, φ-anchor 0x47C0 invariant, slashing |
| `JobProver.sol` | 114 | Groth16 BN254 wrapper for B5 ZK Job Proof (precompile 0x08) |
| `IGLALedger.sol` | 390 | Champion BPB lock (22393, step 27000, sha 0x2446855) |
| `BittensorSubnetAttest.sol` | 76 | B9 Bittensor pilot attestor (SN3/SN39/SN81) |

Total: **1,357 lines of Solidity**.

## Mining Protocol (the 7 checks)

Every successful `MiningPool.claimReward()` requires:

1. **B5 ZK Groth16 proof** on BN254 (precompile 0x08)
2. **2-of-3 chip signatures** — any 2 of Phi/Euler/Gamma must co-sign
3. **Unique PUF fingerprint** registered in `ChipRegistry`
4. **φ-anchor 0x47C0** cross-die invariant verified (TG-TRIAD-X Theorem 36.1)
5. **BPB score ≤ 22393** (= champion 2.2393 × 10000, locked by `IGLALedger`)
6. **Anti-flood** — minimum 24h between claims per chip
7. **Not slashed** — chip must not be in slashed state in registry

## Emission Curve

| Era | Years | Reward/proof | Era supply | Cumulative |
|---:|---|---:|---:|---:|
| 0 | 2026-2030 | 1,000 TRI | 3.81T | 50.000% |
| 1 | 2030-2034 | 500 TRI | 1.91T | 75.000% |
| 2 | 2034-2038 | 250 TRI | 953B | 87.500% |
| 3 | 2038-2042 | 125 TRI | 477B | 93.750% |
| 4 | 2042-2046 | 62.5 TRI | 238B | 96.875% |
| 5 | 2046-2050 | 31.25 TRI | 119B | 98.438% |
| 6 | 2050-2054 | 15.625 TRI | 60B | 99.219% |
| 7 | 2054-2058 | 7.8125 TRI | 30B | 99.609% |
| 8 | 2058-2062 | 3.90625 TRI | 15B | 99.805% |
| 9 | 2062-2066 | 1.953125 TRI | 7.4B | 100.000% |

Final coin mined ~2066. **9 halvings = 36 opcodes of the TRI-27 kernel** (not coincidence).

## Anti-Fleet (sublinear reward scaling)

```
reward(n_chips) = base_reward × sqrt(n_chips)
```

100 chips earn only 10× the reward, not 100×. Whale fleets are economically
uninteresting. Geographic decentralization bonus +20% via RIPE Atlas ZK
location proof (Era 1+).

## Quick Start

```bash
# Install
git clone https://github.com/gHashTag/trinity-contracts.git
cd trinity-contracts
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit

# Build
forge build

# Test
forge test -vv

# Deploy to Base Sepolia
export DEPLOYER_PRIVATE_KEY=0x...
export BASE_SEPOLIA_RPC=https://sepolia.base.org
export BASESCAN_API_KEY=...

forge script script/DeployAll.s.sol \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

## Hardware Linkage

This contract suite is paired with three Tiny Tapeout SKY130A submissions:

| Chip | Tiles | Role | Submission |
|---|---:|---|---|
| [TRI-1 Phi](https://github.com/gHashTag/tt-trinity-phi) | 1 | φ-anchor 0x47C0 cross-die invariant | #4914 |
| [TRI-1 Euler](https://github.com/gHashTag/tt-trinity-euler) | 16 | e-engine SUPER-CROWN + 10 CLARA Gaps | #4915 |
| [TRI-1 Gamma](https://github.com/gHashTag/tt-trinity-gamma) | 32 | γ-surface neuromorphic flagship | #4913 |

Each chip exposes a `champion_bpb_oracle` ROM module reading the canonical
anchor 0x47C0, BPB lock 22393 (Q4.12 = 0x23D3), and version 0x0100 — the
hardware-side handshake for `ChipRegistry.registerChip()`.

## Related Repositories

- [gHashTag/NeuronConstant](https://github.com/gHashTag/NeuronConstant) — canonical chip-block catalog
- [gHashTag/trinity-node](https://github.com/gHashTag/trinity-node) — Rust DePIN daemon
- [gHashTag/trinity-sdk](https://github.com/gHashTag/trinity-sdk) — Python SDK
- [gHashTag/trinity-bittensor](https://github.com/gHashTag/trinity-bittensor) — BIT-0011 attestor

## License

Apache-2.0. Sole author: **Dmitrii Vasilev** ([admin@t27.ai](mailto:admin@t27.ai)).

DOI: [10.5281/zenodo.19227877](https://doi.org/10.5281/zenodo.19227877)

φ² + φ⁻² = 3
