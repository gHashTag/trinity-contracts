// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ChipRegistry}        from "../src/ChipRegistry.sol";
import {JobProver}           from "../src/JobProver.sol";
import {EmissionController}  from "../src/EmissionController.sol";
import {MiningPool}          from "../src/MiningPool.sol";
import {TriToken}            from "../src/TriToken.sol";

/**
 * @title DeployAll
 * @notice One-shot deployment for the Trinity mining protocol on Base.
 *
 *         Deployment order resolves the circular ChipRegistry↔MiningPool↔TriToken
 *         dependency by precomputing the future TriToken address using the
 *         deployer nonce, allowing MiningPool to be constructed with the
 *         correct token reference before TriToken is actually deployed.
 *
 *         Order (deployer nonce):
 *           N+0  ChipRegistry
 *           N+1  JobProver
 *           N+2  EmissionController
 *           N+3  MiningPool         (refs ChipRegistry + computed TriToken at N+4)
 *           N+4  TriToken           (mints 7.625T TRI to MiningPool, renounces ownership)
 *
 *         TriToken's constructor calls renounceOwnership() internally. MiningPool
 *         ownership is renounced explicitly at the end (no further setters needed).
 *
 *         Usage:
 *           forge script script/DeployAll.s.sol \
 *             --rpc-url base_sepolia --broadcast --verify
 */
contract DeployAll is Script {

    function run() external {
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint64  nonce    = vm.getNonce(deployer);

        // Compute future addresses based on nonce.
        // N+0 chipRegistry, N+1 jobProver, N+2 emission, N+3 miningPool, N+4 triToken
        address predictedTriToken = vm.computeCreateAddress(deployer, nonce + 4);

        vm.startBroadcast(pk);

        // ─── N+0  ChipRegistry ──────────────────────────────────────────────
        ChipRegistry registry = new ChipRegistry();
        console.log("ChipRegistry        :", address(registry));

        // ─── N+1  JobProver ────────────────────────────────────────────────
        JobProver prover = new JobProver();
        console.log("JobProver           :", address(prover));

        // ─── N+2  EmissionController ───────────────────────────────────────
        EmissionController emission = new EmissionController();
        console.log("EmissionController  :", address(emission));

        // ─── N+3  MiningPool (gets predicted TriToken address) ─────────────
        MiningPool pool = new MiningPool(
            predictedTriToken,
            address(registry),
            block.timestamp        // GENESIS
        );
        console.log("MiningPool          :", address(pool));

        // ─── N+4  TriToken (mints 7.625T to MiningPool, renounces ownership)
        TriToken tri = new TriToken(address(pool));
        console.log("TriToken            :", address(tri));

        // Sanity — predicted must equal actual.
        require(address(tri) == predictedTriToken, "DeployAll: TriToken address mismatch");

        // Renounce MiningPool ownership.
        pool.renounceOwnership();

        console.log("--- Deploy complete. All ownerships renounced. ---");
        console.log("TOTAL_SUPPLY (TRI)  :", tri.TOTAL_SUPPLY() / 1e18);
        console.log("Pool TRI balance    :", tri.balanceOf(address(pool)) / 1e18);

        vm.stopBroadcast();
    }
}
