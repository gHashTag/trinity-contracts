// SPDX-License-Identifier: Apache-2.0
// Author: Dmitrii Vasilev (sole author, admin@t27.ai)
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TriToken.sol";

/**
 * @title TriToken.t.sol
 * @notice Foundry test suite for TriToken — covers supply, constants,
 *         pre-mine absence, burn mechanics, and ownership renunciation.
 */
contract TriTokenTest is Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Test fixtures
    // ─────────────────────────────────────────────────────────────────────────

    TriToken public token;

    address public miningPool = makeAddr("miningPool");
    address public alice      = makeAddr("alice");

    uint256 public constant EXPECTED_SUPPLY =
        7_625_597_484_987 * 10 ** 18;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        token = new TriToken(miningPool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testTotalSupply
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice totalSupply() must exactly equal 7,625,597,484,987 × 10^18.
    function testTotalSupply() public view {
        assertEq(
            token.totalSupply(),
            EXPECTED_SUPPLY,
            "totalSupply must equal 3^27 * 10**18"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testConstants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Verify compile-time constants match the spec.
    function testConstants() public view {
        assertEq(token.TOTAL_SUPPLY(),          EXPECTED_SUPPLY,      "TOTAL_SUPPLY");
        assertEq(token.TRINITY_KERNEL_STATES(),  7_625_597_484_987,    "TRINITY_KERNEL_STATES");
        assertEq(uint256(token.PHI_ANCHOR()),    0x47C0,               "PHI_ANCHOR");
        assertEq(uint256(token.CHAMPION_BPB()),  22_393,               "CHAMPION_BPB");
        assertEq(uint256(token.CHAMPION_STEP()), 27_000,               "CHAMPION_STEP");
        assertEq(uint256(token.CHAMPION_SEED()), 43,                   "CHAMPION_SEED");
        assertEq(uint256(token.CHAMPION_SHA()),  0x2446855,            "CHAMPION_SHA");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testNoPreMint
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice The zero address holds no tokens, and the miningPool address
     *         holds 100 % of supply — no tokens are pre-mined to any other
     *         address, including the deployer.
     */
    function testNoPreMint() public view {
        // address(0) has nothing.
        assertEq(
            token.balanceOf(address(0)),
            0,
            "address(0) must have zero balance"
        );

        // miningPool holds the entire supply.
        assertEq(
            token.balanceOf(miningPool),
            EXPECTED_SUPPLY,
            "miningPool must hold 100% of supply"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testBurn
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Burning 100 TRI reduces the holder's balance and totalSupply
     *         by exactly 100 × 10^18 wei.
     */
    function testBurn() public {
        uint256 burnAmount   = 100 * 10 ** 18;
        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore    = token.balanceOf(miningPool);

        // Fund alice with 100 TRI from the mining pool.
        vm.prank(miningPool);
        token.transfer(alice, burnAmount);

        // Alice burns her 100 TRI.
        vm.prank(alice);
        token.burn(burnAmount);

        // Supply decreased by exactly burnAmount.
        assertEq(
            token.totalSupply(),
            supplyBefore - burnAmount,
            "totalSupply must decrease by burned amount"
        );

        // Alice's balance is now zero.
        assertEq(
            token.balanceOf(alice),
            0,
            "alice balance must be zero after burn"
        );

        // Mining pool balance is unchanged (alice already received the tokens).
        assertEq(
            token.balanceOf(miningPool),
            balBefore - burnAmount,
            "miningPool balance must reflect transfer to alice"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testRenouncedOwnership
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Ownership must be renounced in the constructor — owner() returns
     *         address(0) immediately after deployment.
     */
    function testRenouncedOwnership() public view {
        assertEq(
            token.owner(),
            address(0),
            "owner must be address(0) after renounceOwnership"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testBurnEvent
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice burn() emits the Burned event with correct parameters.
     */
    function testBurnEvent() public {
        uint256 burnAmount = 1 * 10 ** 18;

        vm.prank(miningPool);
        token.transfer(alice, burnAmount);

        vm.expectEmit(true, false, false, true, address(token));
        emit TriToken.Burned(alice, burnAmount);

        vm.prank(alice);
        token.burn(burnAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // testCannotMint
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice There is no mint() function — verifying this at the ABI level
     *         via a low-level call that must revert.
     */
    function testCannotMint() public {
        bytes memory mintCall = abi.encodeWithSignature(
            "mint(address,uint256)",
            alice,
            1 ether
        );
        (bool success, ) = address(token).call(mintCall);
        assertFalse(success, "mint() must not exist or must revert");
    }
}
