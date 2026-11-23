// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {EntityForging} from "traitforge/EntityForging/EntityForging.sol";
import {MockNftForForging} from "./mocks/SharedMocks.sol";

/// @title EntityForging PoCs (frozen sample 2024-07-traitforge)
/// @notice P1: excess msg.value is trapped forever (no receive/fallback/withdraw).
///         P5: a forger can be used forgePotential+1 times because the limit is
///             only checked when listing, never when forging.
contract EntityForgingPoC is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant NUKE = address(0xBEEF);

    uint256 internal constant FEE = 1 ether;

    EntityForging internal forging;
    MockNftForForging internal nft;

    function setUp() public {
        nft = new MockNftForForging();
        forging = new EntityForging(address(nft));
        forging.setNukeFundAddress(payable(NUKE));
    }

    /// @dev P1 — EntityForging.sol L126 accepts msg.value >= forgingFee but
    ///      L146-159 only pays out devFee + forgerShare == forgingFee.
    ///      The surplus stays in a contract that has no receive/fallback and no
    ///      withdraw function, so it is locked forever.
    function test_PoC_P1_excessPaymentLocked() public {
        // forger token: entropy 21 -> 21 % 3 == 0 (forger), (21/10)%10 == 2
        // merger token: entropy 11 -> 11 % 3 == 2 (merger), (11/10)%10 == 1
        nft.setToken(1, ALICE, 21, 1);
        nft.setToken(2, BOB, 11, 1);

        vm.prank(ALICE);
        forging.listForForging(1, FEE);

        uint256 aliceBefore = ALICE.balance;
        uint256 nukeBefore = NUKE.balance;

        vm.deal(BOB, 10 ether);
        vm.prank(BOB);
        forging.forgeWithListed{value: 3 * FEE}(1, 2);

        uint256 forgerPaid = ALICE.balance - aliceBefore;
        uint256 nukePaid = NUKE.balance - nukeBefore;
        uint256 locked = address(forging).balance;

        console.log("P1 forgingFee (listing)      :", FEE);
        console.log("P1 msg.value sent           :", 3 * FEE);
        console.log("P1 forger owner received    :", forgerPaid);
        console.log("P1 nukeFund received        :", nukePaid);
        console.log("P1 ETH stuck in EntityForging:", locked);

        // Only forgingFee (= 0.9 + 0.1) was distributed, the 2x surplus stayed.
        assertEq(forgerPaid, 0.9 ether, "forger share must be forgingFee*0.9");
        assertEq(nukePaid, 0.1 ether, "nuke share must be forgingFee*0.1");
        assertEq(locked, 2 * FEE, "excess payment must be stuck in the contract");

        // No function can move it: the ABI has no withdraw/fallback.
        (bool ok, ) = address(forging).call(abi.encodeWithSignature("withdraw()"));
        console.log("P1 withdraw() call succeeded:", ok);
        assertFalse(ok, "EntityForging must not expose a withdraw()");
        assertEq(address(forging).balance, 2 * FEE, "locked balance is unrecoverable");
    }

    /// @dev P5 — listForForging L87-90 checks `forgingCounts <= forgePotential`
    ///      (off-by-one) and forgeWithListed L133 only increments. So a forger
    ///      with forgePotential P can be listed and forged P+1 times.
    function test_PoC_P5_forgerUsedPotentialPlusOne() public {
        // forger token 1: entropy 21 -> isForger, forgePotential = (21/10)%10 = 2
        nft.setToken(1, ALICE, 21, 1);
        // three merger tokens: entropy 11 -> not forger, forgePotential = 1
        nft.setToken(2, BOB, 11, 1);
        nft.setToken(3, BOB, 11, 1);
        nft.setToken(4, BOB, 11, 1);

        uint256 forgerPotential = (uint256(21) / 10) % 10; // 2, mirrors the contract
        vm.deal(BOB, 10 ether);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(ALICE);
            forging.listForForging(1, FEE);
            vm.prank(BOB);
            forging.forgeWithListed{value: FEE}(1, 2 + i);
        }

        uint256 used = forging.forgingCounts(1);
        console.log("P5 forgePotential (entropy 21):", forgerPotential);
        console.log("P5 successful forges         :", used);
        console.log("P5 listings consumed         :", forging.listingCount());

        assertEq(used, 3, "third forge must succeed despite potential == 2");
        assertGt(used, forgerPotential, "forger used more than forgePotential times");
        assertEq(used, forgerPotential + 1, "exactly P+1 uses, not bounded by P");
    }

    /// @dev P12 — `taxCut` is a percentage (10 means 10%) but the fee split uses it
    ///      as a divisor: `forgingFee / taxCut`. That is only correct because the
    ///      deployed value happens to be 10. Any other value mis-splits the fee, and
    ///      zero makes the division revert, taking the forge path, the trading path
    ///      and the fund's receive path with it.
    function test_PoC_P12_taxCutDivisorMisprices() public {
        nft.setToken(1, ALICE, 21, 1); // forger
        nft.setToken(2, BOB, 11, 1); // merger
        vm.deal(BOB, 10 ether);

        // owner lowers the cut to 5%: the split should be 0.05 / 0.95
        forging.setTaxCut(5);

        vm.prank(ALICE);
        forging.listForForging(1, FEE);

        uint256 nukeBefore = NUKE.balance;
        uint256 aliceBefore = ALICE.balance;
        vm.prank(BOB);
        forging.forgeWithListed{value: FEE}(1, 2);

        uint256 devShare = NUKE.balance - nukeBefore;
        uint256 forgerShare = ALICE.balance - aliceBefore;
        console.log("P12 taxCut set                :", forging.taxCut());
        console.log("P12 treasury share (wei)      :", devShare);
        console.log("P12 forger share (wei)       :", forgerShare);

        // Bug: 1 ETH / 5 = 0.2 (20%), not 5%.
        assertEq(devShare, 0.2 ether, "5% cut is applied as a divisor: the treasury takes 20%");
        assertEq(forgerShare, 0.8 ether, "the forger keeps 80% instead of 95%");

        // A zero cut bricks the split entirely: division by zero.
        forging.setTaxCut(0);
        nft.setToken(3, ALICE, 21, 1);
        nft.setToken(4, BOB, 11, 1);
        vm.prank(ALICE);
        forging.listForForging(3, FEE);
        vm.prank(BOB);
        vm.expectRevert();
        forging.forgeWithListed{value: FEE}(3, 4);
    }
}
