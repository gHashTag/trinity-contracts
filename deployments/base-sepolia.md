# Base Sepolia Deployment — Trinity Network v1.0

**Chain:** Base Sepolia (chain ID 84532)
**Deployer:** `0x96D3bB6C671644084DB0838bC5dC16762B9cFaC7` (ephemeral, deploy-only)
**Date:** 2026-05-18 15:21 UTC
**Block range:** 41,674,689 → 41,674,694
**Total gas:** 4,540,550 (across 7 transactions)
**Cost:** ~0.0000275 ETH

## Contracts

| Contract | Address | Deploy TX |
|---|---|---|
| **TriToken** (ERC20+Permit+Votes) | [`0x7D3ECaB5c467bd86050f9160B15c002a57249c59`](https://sepolia.basescan.org/address/0x7D3ECaB5c467bd86050f9160B15c002a57249c59) | [`0xf539eb3f...12dd2a34`](https://sepolia.basescan.org/tx/0xf539eb3f4550759280f3af6e4903aa11ea9598228f715b642e5c1cfe12dd2a34) |
| **MiningPool** | [`0xAe28EDd6c13fd8B3b5C217fd705488B30683c45E`](https://sepolia.basescan.org/address/0xAe28EDd6c13fd8B3b5C217fd705488B30683c45E) | [`0x74d610c0...d61f9e614`](https://sepolia.basescan.org/tx/0x74d610c018ef6cf92aa86a2e7ddc6a598fe7472711dbcf5c73b9373d61f9e614) |
| **EmissionController** | [`0x5Abb2aB9D97ac56BD7B4c8dF1964C150393b9520`](https://sepolia.basescan.org/address/0x5Abb2aB9D97ac56BD7B4c8dF1964C150393b9520) | [`0xc9b6acdd...61d969788`](https://sepolia.basescan.org/tx/0xc9b6acddabaee9a9a704e3ed5e8630907c8a28eae77b83fcce6194161d969788) |
| **ChipRegistry** | [`0xB52F010494f5074F1Ee4EE60e1374c0aF7a29630`](https://sepolia.basescan.org/address/0xB52F010494f5074F1Ee4EE60e1374c0aF7a29630) | [`0xf4818465...5b6f22a41b`](https://sepolia.basescan.org/tx/0xf4818465ac31b0abb8d41571100d08031e28049e62604a21a845925b6f22a41b) |
| **JobProver** | [`0x4e8971984f7C8eaDFf76F68cF6D6D9134C3dD9F5`](https://sepolia.basescan.org/address/0x4e8971984f7C8eaDFf76F68cF6D6D9134C3dD9F5) | [`0x72ac4d74...0304e418c`](https://sepolia.basescan.org/tx/0x72ac4d747537d4c53e03530de2c04fd3c342df7a01b4baf1557be5d0304e418c) |

## On-chain Invariants Verified

- ✅ `TriToken.totalSupply()` = `7,625,597,484,987 × 10^18` wei = **3²⁷ TRI**
- ✅ `TriToken.balanceOf(MiningPool)` = `totalSupply` (100% in pool, 0% pre-mine)
- ✅ `TriToken.owner()` = `address(0)` (renounced — cannot mint more, ever)
- ✅ `MiningPool.owner()` = `address(0)` (renounced — contract immutable)
- ✅ `MiningPool.triToken()` = TriToken address (circular dep solved via `vm.computeCreateAddress`)

## Tokenomics

- **Total supply:** 7,625,597,484,987 TRI (3²⁷, locked)
- **Decimals:** 18
- **Pre-mine:** 0%
- **Mineable:** 100%
- **Halvings:** 9, every 4 years
- **Era 0 reward:** 1,000 TRI per proof (2026–2030, 50% of supply)
- **Final coin mined:** ~2066

## Hardware-Software Handshake

- Chip `champion_bpb_oracle` ROM exposes:
  - `0x47C0` — canonical anchor (TG-TRIAD-X Theorem 36.1)
  - `0x23D3` — BPB Q4.12 fixed-point (= 2.23847)
  - `0x0100` — version (1.00)
- `ChipRegistry.registerChip()` requires `phiAnchorOut == 0x47C0`
- `JobProver.verifyProof()` requires `publicInputs[3] <= 22393` (CHAMPION_BPB)
- 2-of-3 attestation: Phi + Euler + Gamma must co-sign

## Mainnet Plan

This Sepolia deployment is for testing. Mainnet deployment on **Base L2** is
**not scheduled**. It is gated on a silicon route, and no fabrication route is
currently selected: the TT SKY26b order was cancelled and refunded in July 2026,
so no chip will be delivered. No mainnet date can be given until a route exists.

For mainnet:
- Genesis timestamp will be set to actual silicon ship date
- ChipRegistry will be populated with on-die PUF fingerprints from delivered chips
- JobProver verifier key will be set from Groth16 trusted setup ceremony
- Deployer will be a multi-sig (Safe) not an EOA
