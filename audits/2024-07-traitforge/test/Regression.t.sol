// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {TraitForgeNft} from "traitforge/TraitForgeNft/TraitForgeNft.sol";
import {EntityForging} from "traitforge/EntityForging/EntityForging.sol";
import {RealWiring} from "./base/RealWiring.sol";
import {
    MockAirdrop,
    MockEntropyGenerator,
    MockForgingRegistry,
    MockNftForForging
} from "./mocks/SharedMocks.sol";

/// @title Regression tests for the combined patch (fixes/ALL)
/// @notice Purpose: fix-fail only shows that a PoC is sensitive to a patch. These
///         tests go the other way — they run the *normal* flows against the same
///         tree after every finding has been fixed, and fail if a fix broke them.
///
///         Two kinds of test live here:
///         - `test_regression_*` — normal behaviour that must hold on any build
///           (mint, forge at the exact fee). These run against the unpatched
///           sources too, so `forge test` stays green on the baseline.
///         - `test_regression_patch_*` — behaviour that only exists once the
///           findings are fixed (rollover keeps pre-fills and the new price, the
///           pause stops minting, the guards reject bad input, the entropy caller
///           role works without an ownership transfer). On an unpatched build the
///           test is reported as skipped instead of failing, because there is
///           nothing to regress against.
///
///         Run against the combined patch:
///         `forge test --remappings 'traitforge/=fixes/ALL/src/' --match-path test/Regression.t.sol`
///
///         The `patched` flag is a single-probe heuristic (it calls F-09's
///         zero-treasury setter). It separates the reviewed commit from the
///         fully-fixed tree; it does not detect a partially patched tree.
contract TraitForgeRegression is Test {
    address internal constant USER = address(0xB0B);
    address internal constant NUKE = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B0);

    uint256 internal constant SLOT_generationMintCounts = 27;
    uint256 internal constant SLOT_currentGeneration = 20;
    uint256 internal constant FEE = 1 ether;

    TraitForgeNft internal nft;
    MockAirdrop internal airdrop;
    MockEntropyGenerator internal entropy;
    MockForgingRegistry internal registry;

    bytes32[] internal emptyProof;
    bool internal patched;

    function setUp() public {
        nft = new TraitForgeNft();
        airdrop = new MockAirdrop();
        entropy = new MockEntropyGenerator();
        registry = new MockForgingRegistry();

        nft.setAirdropContract(address(airdrop));
        nft.setEntropyGenerator(address(entropy));
        nft.setEntityForgingContract(address(registry));
        nft.setNukeFundContract(payable(NUKE));
        nft.setWhitelistEndTime(0);

        vm.deal(USER, 1_000 ether);
        vm.deal(BOB, 1_000 ether);

        // Probe: F-09 makes the zero-treasury setter revert. Accepted means the
        // sources are unpatched; restore the address and skip the fix-only tests.
        try nft.setNukeFundContract(payable(address(0))) {
            patched = false;
            nft.setNukeFundContract(payable(NUKE));
        } catch {
            patched = true;
        }
    }

    modifier whenPatched() {
        if (!patched) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _setGenMintCount(uint256 generation, uint256 value) internal {
        vm.store(
            address(nft),
            keccak256(abi.encode(generation, SLOT_generationMintCounts)),
            bytes32(value)
        );
    }

    function _setCurrentGeneration(uint256 value) internal {
        vm.store(address(nft), bytes32(SLOT_currentGeneration), bytes32(value));
    }

    // ------------------------------------------------------- always-on flows

    /// @dev A plain public mint still works and still pays the first price.
    function test_regression_singleMint() public {
        uint256 price = nft.calculateMintPrice();
        assertEq(price, 0.005 ether, "generation-1 opening price");

        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);

        assertEq(nft.totalSupply(), 1, "one token minted");
        assertEq(nft.ownerOf(1), USER, "minter owns the token");
        assertEq(USER.balance, 1_000 ether - price, "minter paid the quoted price");
        assertEq(nft.generationMintCounts(1), 1, "generation counter advanced once");
    }

    /// @dev Forging at exactly the listed fee still works, and the fee is still
    ///      split 90/10 between the forger owner and the treasury.
    function test_regression_forgeAtExactFee() public {
        MockNftForForging mockNft = new MockNftForForging();
        EntityForging forging = new EntityForging(address(mockNft));
        forging.setNukeFundAddress(payable(NUKE));

        // token 1: entropy 21 -> forger with potential 2; token 2: merger
        mockNft.setToken(1, ALICE, 21, 1);
        mockNft.setToken(2, BOB, 11, 1);

        vm.prank(ALICE);
        forging.listForForging(1, FEE);

        uint256 aliceBefore = ALICE.balance;
        uint256 nukeBefore = NUKE.balance;

        vm.prank(BOB);
        forging.forgeWithListed{value: FEE}(1, 2);

        assertEq(forging.forgingCounts(1), 1, "forger used once");
        assertEq(ALICE.balance - aliceBefore, 0.9 ether, "forger share");
        assertEq(NUKE.balance - nukeBefore, 0.1 ether, "treasury share");
        assertEq(address(forging).balance, 0, "exact payment leaves nothing behind");
    }

    // ------------------------------------------------- fix-only regressions

    /// @dev F-03 + F-04: the rollover keeps the pre-filled generation-2 count and
    ///      prices from the new generation's curve — starting *at* that pre-fill,
    ///      because those entities occupy the first slots of the generation.
    function test_regression_patch_rolloverKeepsPrefillAndPrice() public whenPatched {
        RealWiring w = new RealWiring(payable(NUKE), true);
        nft = w.nft();
        vm.deal(USER, 1_000 ether);

        uint256 prefill = 5;
        _setGenMintCount(1, nft.maxTokensPerGen());
        _setGenMintCount(2, prefill);

        // Quote before the prank: vm.prank applies to the next call, and a view
        // call would consume it.
        uint256 quoted = nft.calculateMintPrice(); // still the old generation's max

        vm.prank(USER);
        nft.mintToken{value: quoted}(emptyProof);

        assertEq(nft.currentGeneration(), 2, "rollover happened");
        assertEq(nft.generationMintCounts(2), prefill + 1, "pre-fill survived the rollover");
        // The 5 pre-filled entities are the first 5 slots of generation 2, so the
        // public mint that follows pays the 6th price on the new curve — not the
        // old generation's maximum (0.25) and not a reset-to-zero curve (0.005).
        uint256 expected = nft.startPrice() + prefill * nft.priceIncrement();
        assertEq(expected, 0.0051475 ether, "new curve continues from the pre-fill");
        assertEq(USER.balance, 1_000 ether - expected, "charged the post-prefill price");
    }

    /// @dev F-08: the owner can now stop and resume minting.
    function test_regression_patch_pauseStopsMinting() public whenPatched {
        // low-level calls: pause()/unpause() do not exist in the unpatched ABI, so
        // a typed call would not compile against both trees.
        (bool okPause, ) = address(nft).call(abi.encodeWithSignature("pause()"));
        assertTrue(okPause, "owner can pause");
        assertTrue(nft.paused(), "contract reports paused");

        uint256 price = nft.calculateMintPrice();
        vm.prank(USER);
        vm.expectRevert();
        nft.mintToken{value: price}(emptyProof);

        (bool okUnpause, ) = address(nft).call(abi.encodeWithSignature("unpause()"));
        assertTrue(okUnpause, "owner can unpause");
        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);
        assertEq(nft.totalSupply(), 1, "minting resumes after unpause");
    }

    /// @dev F-05 + F-09: the guards reject overpayment and a zero treasury
    ///      instead of trapping or burning the funds.
    function test_regression_patch_guards() public whenPatched {
        vm.expectRevert(bytes("Zero address"));
        nft.setNukeFundContract(payable(address(0)));

        MockNftForForging mockNft = new MockNftForForging();
        EntityForging forging = new EntityForging(address(mockNft));
        forging.setNukeFundAddress(payable(NUKE));
        mockNft.setToken(1, ALICE, 21, 1);
        mockNft.setToken(2, BOB, 11, 1);
        vm.prank(ALICE);
        forging.listForForging(1, FEE);

        vm.prank(BOB);
        vm.expectRevert(bytes("Incorrect fee"));
        forging.forgeWithListed{value: 3 * FEE}(1, 2);
    }

    /// @dev F-10: the rollover works while the deployer keeps ownership of the
    ///      entropy generator, so the administrative role is still reachable.
    function test_regression_patch_entropyCallerRole() public whenPatched {
        RealWiring w = new RealWiring(payable(NUKE), false);
        nft = w.nft();
        vm.deal(USER, 1_000 ether);

        assertEq(w.entropy().owner(), address(w), "deployer still owns the generator");
        _setGenMintCount(1, nft.maxTokensPerGen());

        vm.prank(USER);
        nft.mintToken{value: 0.25 ether}(emptyProof);
        assertEq(nft.currentGeneration(), 2, "rollover succeeded without an ownership transfer");
    }

    /// @dev F-02 + F-01 + F-04 interaction: a budget mint that reaches a
    ///      generation boundary must mint up to that boundary and refund the
    ///      remainder. At the LAST generation it must stop at the cap instead of
    ///      reverting the whole call (the loop settles after every mint, and the
    ///      cap check inside _incrementGeneration would otherwise revert once the
    ///      final token has been minted).
    function test_regression_patch_budgetMintAcrossBoundary() public whenPatched {
        RealWiring w = new RealWiring(payable(NUKE), true);
        nft = w.nft();
        vm.deal(USER, 1_000 ether);

        // leg 1 — generation 1 is full, the budget spans into generation 2
        _setGenMintCount(1, nft.maxTokensPerGen());
        assertEq(nft.calculateMintPrice(), 0.25 ether, "quoted the maxed-out generation-1 price");

        uint256 budget = 0.1 ether;
        uint256 balanceBefore = USER.balance;
        vm.prank(USER);
        nft.mintWithBudget{value: budget}(emptyProof);

        uint256 minted = nft.totalSupply();
        uint256 spent = balanceBefore - USER.balance;
        assertGt(minted, 0, "budget mint produced tokens");
        assertEq(nft.currentGeneration(), 2, "crossed into generation 2");
        assertEq(nft.generationMintCounts(1), nft.maxTokensPerGen(), "generation 1 stayed at its cap");
        assertEq(nft.generationMintCounts(2), minted, "every new token is a generation-2 token");

        // The charge must equal the sum of the per-token prices on the new curve.
        uint256 price = nft.startPrice();
        uint256 inc = nft.priceIncrement();
        uint256 expectedSum;
        uint256 expectedCount;
        while (expectedSum + price <= budget) {
            expectedSum += price;
            price += inc;
            expectedCount++;
        }
        assertEq(minted, expectedCount, "minted exactly what the budget covers");
        assertEq(spent, expectedSum, "charged the sum of the per-token prices");

        // leg 1b — a boundary that is NOT the last generation must keep minting:
        // generation 9 is full, so the batch rolls into 10 and continues there.
        _setCurrentGeneration(9);
        _setGenMintCount(9, nft.maxTokensPerGen());
        uint256 budget9 = 0.05 ether;
        uint256 supplyBefore9 = nft.totalSupply();
        vm.prank(USER);
        nft.mintWithBudget{value: budget9}(emptyProof);

        uint256 minted9 = nft.totalSupply() - supplyBefore9;
        assertEq(nft.currentGeneration(), 10, "rolled from 9 into 10");
        assertEq(nft.generationMintCounts(10), minted9, "minting continued inside generation 10");
        assertGt(minted9, 0, "tokens were minted after the non-final boundary");

        uint256 price9 = nft.startPrice();
        uint256 inc9 = nft.priceIncrement();
        uint256 sum9;
        uint256 count9;
        while (sum9 + price9 <= budget9) {
            sum9 += price9;
            price9 += inc9;
            count9++;
        }
        assertEq(minted9, count9, "the non-final boundary charges the new curve too");

        // leg 2 — one token left before the absolute cap of the last generation.
        // Injected state: currentGeneration and generationMintCounts[10] are
        // fast-forwarded (10,000 real mints are impractical here); priceIncrement
        // is left at its generation-2 value, so the quoted price is not the price
        // a real generation 10 would quote. The assertions only use the quoted
        // value, not a hard-coded one.
        _setCurrentGeneration(10);
        _setGenMintCount(10, nft.maxTokensPerGen() - 1);
        uint256 capPrice = nft.calculateMintPrice();
        uint256 supplyBefore = nft.totalSupply();
        uint256 balanceBefore2 = USER.balance;

        vm.prank(USER);
        nft.mintWithBudget{value: capPrice * 3}(emptyProof);

        assertEq(nft.totalSupply(), supplyBefore + 1, "only the last token was mintable");
        assertEq(nft.generationMintCounts(10), nft.maxTokensPerGen(), "cap reached exactly");
        assertEq(balanceBefore2 - USER.balance, capPrice, "charged for one token; the rest refunded");

        // Once the cap is reached the batch is rejected rather than accepting ETH.
        vm.prank(USER);
        vm.expectRevert(bytes("Exceeds max generations"));
        nft.mintWithBudget{value: capPrice}(emptyProof);
    }

    /// @dev Forging through the real EntityForging on the real NFT still works:
    ///      the child is minted into the next generation and the fee is split
    ///      90/10. Entropy is chosen through the mock stream so the forger has a
    ///      known potential.
    function test_regression_realForge() public {
        EntityForging forging = new EntityForging(address(nft));
        forging.setNukeFundAddress(payable(NUKE));
        nft.setEntityForgingContract(address(forging));

        // token 1: entropy 21 -> forger, potential 2; token 2: entropy 11 -> merger
        entropy.setCounter(20);
        uint256 price1 = nft.calculateMintPrice();
        vm.prank(USER);
        nft.mintToken{value: price1}(emptyProof);

        entropy.setCounter(10);
        uint256 price2 = nft.calculateMintPrice();
        vm.prank(BOB);
        nft.mintToken{value: price2}(emptyProof);

        vm.prank(USER);
        forging.listForForging(1, FEE);

        uint256 userBefore = USER.balance;
        uint256 nukeBefore = NUKE.balance;
        vm.prank(BOB);
        forging.forgeWithListed{value: FEE}(1, 2);

        assertEq(nft.totalSupply(), 3, "child minted");
        assertEq(nft.getTokenGeneration(3), 2, "child belongs to the next generation");
        assertEq(forging.forgingCounts(1), 1, "forger used once");
        assertEq(USER.balance - userBefore, 0.9 ether, "forger share");
        assertEq(NUKE.balance - nukeBefore, 0.1 ether, "treasury share");
    }

    /// @dev F-07: burning a token that changed hands debits the current owner,
    ///      not the address that minted it.
    function test_regression_patch_burnDebitsCurrentOwner() public whenPatched {
        airdrop.setStarted(false);

        entropy.setCounter(100);
        uint256 price = nft.calculateMintPrice();
        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);

        vm.prank(USER);
        nft.transferFrom(USER, BOB, 1);
        vm.prank(BOB);
        nft.burn(1);

        assertEq(airdrop.subCallCount(), 1, "burn performed exactly one debit");
        assertEq(airdrop.lastDebitedUser(), BOB, "burn debited the current owner");
        assertEq(airdrop.lastDebited(USER), 0, "the original minter was not charged");
    }
}
