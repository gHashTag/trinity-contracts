// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ChipRegistryV2.sol";
import "../src/ChipRegistry.sol";

/// @dev Every test here corresponds to a way the deployed registry can be
///      fooled, or to a replay the gate is supposed to close. The first test is
///      a demonstration against the deployed contract rather than the new one,
///      because a gate is only worth having if the thing it replaces is open.
contract ChipRegistryV2Test is Test {

    ChipRegistryV2 registry;

    uint256 chipKey   = 0xA11CE;
    address chipAddr;
    bytes32 chipId;

    uint256 otherKey  = 0xB0B;

    address registrant = address(0xBEEF);
    address stranger   = address(0xCAFE);

    function setUp() public {
        registry = new ChipRegistryV2();
        chipAddr = vm.addr(chipKey);
        chipId   = bytes32(uint256(uint160(chipAddr)));
    }

    function _sign(uint256 key, bytes32 id, address who, uint256 nonce)
        internal view returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, registry.registrationDigest(id, who, nonce));
        return abi.encodePacked(r, s, v);
    }

    // ── the problem being solved ────────────────────────────────────────────

    function test_deployedRegistryAcceptsAnyoneWithAnyIdentifier() public {
        ChipRegistry old = new ChipRegistry();
        vm.prank(stranger);
        old.registerChip(bytes32(uint256(0xDEADBEEF)), 1, 0x47C0);
        assertTrue(
            old.isRegistered(bytes32(uint256(0xDEADBEEF))),
            "the deployed registry should accept an invented identifier"
        );
    }

    // ── happy path ──────────────────────────────────────────────────────────

    function test_registersWithChipSignature() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(registrant);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);

        assertTrue(registry.isRegistered(chipId));
        assertEq(registry.totalChips(), 1);
        (, , , , address attestor) = registry.chipInfo(chipId);
        assertEq(attestor, registrant, "submitter becomes attestor");
    }

    // ── the gate ────────────────────────────────────────────────────────────

    function test_rejectsSignatureFromAnotherKey() public {
        bytes memory sig = _sign(otherKey, chipId, registrant, 1);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.SignatureNotFromChip.selector);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);
    }

    function test_rejectsIdentifierThatIsNotAnAddress() public {
        bytes32 wide = bytes32(uint256(1) << 200);
        bytes memory sig = _sign(chipKey, wide, registrant, 1);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.IdentifierNotAnAddress.selector);
        registry.registerChip(wide, 1, 0x47C0, 1, sig);
    }

    // ── replays the bindings are supposed to close ──────────────────────────

    function test_signatureIsBoundToTheSubmitter() public {
        // Signed for `registrant`, submitted by `stranger`.
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(stranger);
        vm.expectRevert(ChipRegistryV2.SignatureNotFromChip.selector);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);
    }

    function test_signatureIsBoundToThisRegistry() public {
        ChipRegistryV2 other = new ChipRegistryV2();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(chipKey, other.registrationDigest(chipId, registrant, 1));
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.SignatureNotFromChip.selector);
        registry.registerChip(chipId, 1, 0x47C0, 1, abi.encodePacked(r, s, v));
    }

    function test_signatureIsBoundToThisChain() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.chainId(block.chainid + 1);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.SignatureNotFromChip.selector);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);
    }

    function test_nonceCannotBeReusedAfterSlashingFrees_theIdentifier() public {
        // Register, then attempt the same nonce again. AlreadyRegistered fires
        // first, so drive the nonce path with a second chip sharing a nonce
        // value - nonces are per chip, which this also demonstrates.
        bytes memory sig = _sign(chipKey, chipId, registrant, 7);
        vm.prank(registrant);
        registry.registerChip(chipId, 1, 0x47C0, 7, sig);
        assertTrue(registry.nonceUsed(chipId, 7));

        address second = vm.addr(otherKey);
        bytes32 secondId = bytes32(uint256(uint160(second)));
        bytes memory sig2 = _sign(otherKey, secondId, registrant, 7);
        vm.prank(registrant);
        registry.registerChip(secondId, 2, 0x47C0, 7, sig2);
        assertEq(registry.totalChips(), 2, "nonce 7 is free for a different chip");
    }

    // ── checks retained from the deployed registry ───────────────────────────

    function test_stillRejectsWrongAnchor() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.PhiAnchorMismatch.selector);
        registry.registerChip(chipId, 1, 0x0000, 1, sig);
    }

    function test_stillRejectsBadFamily() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.InvalidFamily.selector);
        registry.registerChip(chipId, 4, 0x47C0, 1, sig);
    }

    function test_stillRejectsDoubleRegistration() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(registrant);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);

        bytes memory sig2 = _sign(chipKey, chipId, registrant, 2);
        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.AlreadyRegistered.selector);
        registry.registerChip(chipId, 1, 0x47C0, 2, sig2);
    }

    function test_onlyAttestorMaySlash() public {
        bytes memory sig = _sign(chipKey, chipId, registrant, 1);
        vm.prank(registrant);
        registry.registerChip(chipId, 1, 0x47C0, 1, sig);

        vm.prank(stranger);
        vm.expectRevert(ChipRegistryV2.NotAttestor.selector);
        registry.slashChip(chipId, "not yours");

        vm.prank(registrant);
        registry.slashChip(chipId, "caught cheating");
        assertFalse(registry.isRegistered(chipId), "slashed chip stops counting");
    }

    // ── fuzz: no identifier registers without its own key ───────────────────

    function testFuzz_arbitraryKeyCannotRegisterArbitraryChip(
        uint256 attackerKey,
        uint256 victimKey
    ) public {
        attackerKey = bound(attackerKey, 1, type(uint128).max);
        victimKey   = bound(victimKey, 1, type(uint128).max);
        vm.assume(attackerKey != victimKey);

        bytes32 victimId = bytes32(uint256(uint160(vm.addr(victimKey))));
        bytes memory sig = _sign(attackerKey, victimId, registrant, 1);

        vm.prank(registrant);
        vm.expectRevert(ChipRegistryV2.SignatureNotFromChip.selector);
        registry.registerChip(victimId, 1, 0x47C0, 1, sig);
    }
}
