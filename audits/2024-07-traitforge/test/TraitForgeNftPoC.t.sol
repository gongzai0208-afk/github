// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TraitForgeNft} from "traitforge/TraitForgeNft/TraitForgeNft.sol";
import {EntropyGenerator} from "traitforge/EntropyGenerator/EntropyGenerator.sol";
import {EntityForging} from "traitforge/EntityForging/EntityForging.sol";
import {RealWiring} from "./base/RealWiring.sol";
import {MockAirdrop, MockEntropyGenerator, MockForgingRegistry} from "./mocks/SharedMocks.sol";

/// @title TraitForgeNft PoCs (frozen sample 2024-07-traitforge)
/// @notice P3/P4/P6/P10 run on the real contracts (test/base/RealWiring.sol):
///         real EntropyGenerator + real EntityForging. P2/P7/P8/P9 keep the
///         lightweight mock wiring from setUp (see the per-test notes).
/// @notice Storage slots below come from
///         `forge inspect TraitForgeNft storage-layout`
///         (OZ ERC721Enumerable/Ownable/Pausable occupy slots 0-11):
///           slot 20 = currentGeneration
///           slot 27 = generationMintCounts (mapping)
///           slot 30 = _tokenIds
contract TraitForgeNftPoC is Test {
    address internal constant USER = address(0xB0B);
    address internal constant NUKE = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B0);
    address internal constant RECEIVER = address(0xCAFE);

    uint256 internal constant SLOT_currentGeneration = 20;
    uint256 internal constant SLOT_generationMintCounts = 27;
    uint256 internal constant SLOT_tokenIds = 30;

    TraitForgeNft internal nft;
    MockAirdrop internal airdrop;
    MockEntropyGenerator internal entropy;
    MockForgingRegistry internal registry;

    bytes32[] internal emptyProof;

    function setUp() public {
        // Mock wiring used by P2/P7/P8/P9. P3/P4/P6/P10 replace it with the real
        // wiring via _useRealWiring().
        nft = new TraitForgeNft();
        airdrop = new MockAirdrop();
        entropy = new MockEntropyGenerator();
        registry = new MockForgingRegistry();

        nft.setAirdropContract(address(airdrop));
        nft.setEntropyGenerator(address(entropy));
        nft.setEntityForgingContract(address(registry));
        nft.setNukeFundContract(payable(NUKE));
        nft.setWhitelistEndTime(0); // disabled: empty merkle proof is accepted

        vm.deal(USER, 1_000 ether);
        vm.label(USER, "minter");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Swap the mock wiring for the real contracts and point the shared
    ///      `nft` / `airdrop` handles at them. The real EntityForging is already
    ///      registered on the NFT, so the real _beforeTokenTransfer path runs on
    ///      every mint/transfer from here on.
    function _useRealWiring(bool transferEntropyOwnership) internal returns (RealWiring w) {
        w = new RealWiring(payable(NUKE), transferEntropyOwnership);
        nft = w.nft();
        airdrop = w.airdrop();
    }

    function _setGenMintCount(uint256 generation, uint256 value) internal {
        // mapping slot 27: keccak256(abi.encode(key, slot))
        vm.store(
            address(nft),
            keccak256(abi.encode(generation, SLOT_generationMintCounts)),
            bytes32(value)
        );
    }

    function _setTokenIds(uint256 value) internal {
        // slot 30 = _tokenIds
        vm.store(address(nft), bytes32(SLOT_tokenIds), bytes32(value));
    }

    function _setCurrentGeneration(uint256 value) internal {
        // slot 20 = currentGeneration
        vm.store(address(nft), bytes32(SLOT_currentGeneration), bytes32(value));
    }

    function _countMinted(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 mintedTopic = keccak256("Minted(address,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == mintedTopic) count++;
        }
    }

    /// @dev P3 helper: scan the real entropy stream and pick a listable forger
    ///      (entropy % 3 == 0, forgePotential > 0, highest potential found) plus
    ///      the first listable mergers (entropy % 3 != 0, forgePotential > 0).
    struct ForgeCandidates {
        uint256 forgerIndex; // token id is forgerIndex + 1
        uint256 forgerPotential; // (entropy / 10) % 10, as used by EntityForging
        uint256 forgerEntropy;
        uint256 mergerCount;
        uint256[] mergers; // scan indices; token id is mergers[k] + 1
    }

    function _scanForgeCandidates(EntropyGenerator gen) internal view returns (ForgeCandidates memory c) {
        uint256 scan = 128;
        c.forgerIndex = type(uint256).max;
        c.mergers = new uint256[](scan);
        for (uint256 i = 0; i < scan; i++) {
            uint256 e = gen.getPublicEntropy(i / 13, i % 13);
            uint256 potential = (e / 10) % 10; // mirrors EntityForging's forgePotential
            if (e % 3 == 0) {
                // forger: listForForging additionally needs forgePotential > 0
                if (potential > c.forgerPotential) {
                    c.forgerPotential = potential;
                    c.forgerIndex = i;
                    c.forgerEntropy = e;
                }
            } else if (potential > 0) {
                // merger: needs entropy % 3 != 0 and forgePotential > 0
                c.mergers[c.mergerCount++] = i;
            }
        }
        require(c.forgerIndex != type(uint256).max, "P3: no listable forger in scan window");
        require(c.mergerCount >= c.forgerPotential, "P3: too few listable mergers in scan window");
    }

    /// @dev P3 helper: mint every gen-1 token needed to cover the chosen indices
    ///      through the real mintToken path, then sanity-check the real entropy
    ///      really matches the pre-computed stream.
    function _mintGen1(ForgeCandidates memory c, EntropyGenerator gen) internal returns (uint256 needed) {
        uint256 n = c.forgerPotential;
        needed = c.forgerIndex + 1;
        if (c.mergers[n - 1] + 1 > needed) needed = c.mergers[n - 1] + 1;
        for (uint256 i = 0; i < needed; i++) {
            uint256 mintPrice = nft.calculateMintPrice();
            vm.prank(USER);
            nft.mintToken{value: mintPrice}(emptyProof);
        }
        assertEq(nft.totalSupply(), needed, "gen-1 tokens minted through the real path");
        assertEq(nft.getTokenEntropy(c.forgerIndex + 1), c.forgerEntropy, "forger entropy mismatch");
        for (uint256 k = 0; k < n; k++) {
            assertEq(
                nft.getTokenEntropy(c.mergers[k] + 1),
                gen.getPublicEntropy(c.mergers[k] / 13, c.mergers[k] % 13),
                "merger entropy mismatch"
            );
        }
    }

    /// @dev P3 helper: distribute the tokens (forger -> ALICE, mergers -> BOB)
    ///      and run N real forgeWithListed() calls, re-listing the forger before
    ///      each one.
    function _distributeAndForge(RealWiring w, ForgeCandidates memory c, uint256 n) internal {
        uint256 forgerId = c.forgerIndex + 1;
        vm.prank(USER);
        nft.transferFrom(USER, ALICE, forgerId);
        for (uint256 k = 0; k < n; k++) {
            vm.prank(USER);
            nft.transferFrom(USER, BOB, c.mergers[k] + 1);
        }
        vm.deal(BOB, 10 ether);
        EntityForging forging = w.forging(); // cache: a view getter would consume the prank
        uint256 fee = forging.minimumListFee();
        for (uint256 k = 0; k < n; k++) {
            uint256 before2 = nft.generationMintCounts(2);
            vm.prank(ALICE);
            forging.listForForging(forgerId, fee);
            vm.prank(BOB);
            forging.forgeWithListed{value: fee}(forgerId, c.mergers[k] + 1);
            assertEq(nft.generationMintCounts(2), before2 + 1, "gen-2 count grew via real forge");
        }
    }

    // ------------------------------------------------------------------ P2

    /// @dev P2 — mintWithBudget loop guard L215 uses the global `_tokenIds`
    ///      counter against the per-generation cap maxTokensPerGen. Once
    ///      _tokenIds reaches maxTokensPerGen the loop body never runs again,
    ///      even though mintToken (per-generation cap, L281) still works.
    ///      Kept on the mock wiring: the PoC is about the loop guard, and the
    ///      local mock entropy makes the mint loop cheap and deterministic.
    function test_PoC_P2_mintWithBudgetDeadAfterMaxSupply() public {
        // Control: the function is alive and mints before supply saturation.
        vm.recordLogs();
        vm.prank(USER);
        nft.mintWithBudget{value: 0.05 ether}(emptyProof);
        uint256 mintedBefore = _countMinted(vm.getRecordedLogs());
        assertGt(mintedBefore, 0, "control: mintWithBudget works before saturation");

        uint256 supplyBefore = nft.totalSupply();
        uint256 balanceBefore = USER.balance;
        _setTokenIds(nft.maxTokensPerGen()); // simulate saturated global supply

        uint256 budget = 1 ether;
        vm.recordLogs();
        vm.prank(USER);
        nft.mintWithBudget{value: budget}(emptyProof);
        uint256 minted = _countMinted(vm.getRecordedLogs());
        int256 netChange = int256(USER.balance) - int256(balanceBefore);
        console.log("P2 control mints before saturation:", mintedBefore);
        console.log("P2 _tokenIds forced to slot30     :", nft.maxTokensPerGen());
        console.log("P2 maxTokensPerGen                :", nft.maxTokensPerGen());
        console.log("P2 budget sent (wei)              :", budget);
        console.log("P2 tokens minted after saturation :", minted);
        console.log("P2 totalSupply before/after       :", supplyBefore);
        console.log("P2 totalSupply after              :", nft.totalSupply());
        console.log("P2 net ETH change for sender      :", netChange);
        console.log("P2 ETH left in NFT contract       :", address(nft).balance);

        assertEq(minted, 0, "mintWithBudget must mint nothing once _tokenIds >= maxTokensPerGen");
        assertEq(nft.totalSupply(), supplyBefore, "no additional token was minted");
        // The 1 ether msg.value was transferred in, so a net-zero balance change
        // proves the full budget was refunded in the same call.
        assertEq(netChange, int256(0), "entire budget must be refunded (net change 0)");
        assertEq(USER.balance, balanceBefore, "sender lost nothing");
        assertEq(address(nft).balance, 0, "contract kept none of the budget");
    }

    // ------------------------------------------------------------------ P3

    /// @dev P3 — _incrementGeneration L351 zeroes generationMintCounts[newGen]
    ///      even though _mintNewEntity (forge path, gen = parent+1) already
    ///      filled counters for that future generation.
    ///
    ///      Real path: the gen-2 pre-fill is produced by N actual
    ///      forgeWithListed() calls against the real EntityForging and real
    ///      EntropyGenerator. Only the "generation 1 is full" precondition is
    ///      injected afterwards (reaching 10,000 real mints is not practical at
    ///      unit-test scale); that precondition IS reachable on-chain, which is
    ///      exactly how gen-2 entities accumulate before the rollover.
    ///
    ///      Fix-fail note: under the alternative F-03 fix that rejects forging
    ///      into a future generation (require gen == currentGeneration in
    ///      TraitForgeNft.forge), every forge below would revert because
    ///      gen 2 > currentGeneration 1 — this PoC could not even build its
    ///      state. The fix this PoC fails under is the other one: stop
    ///      zeroing generationMintCounts[newGen] in _incrementGeneration (keep
    ///      the forged pre-fill), after which the count is N+1 instead of 1.
    function test_PoC_P3_generationCountWipedOnRollover() public {
        RealWiring w = _useRealWiring(true);
        EntropyGenerator gen = w.entropy();

        // 1) Pick a listable forger and listable mergers from the REAL entropy
        //    stream before minting (see _scanForgeCandidates).
        ForgeCandidates memory c = _scanForgeCandidates(gen);
        uint256 n = c.forgerPotential; // exactly P forges: this PoC does not rely on the F-06 off-by-one

        // 2) Mint the chosen gen-1 tokens through the real mintToken path.
        uint256 gen1Supply = _mintGen1(c, gen);

        // 3) Forger -> ALICE, chosen mergers -> BOB (forgeWithListed requires a
        //    merger owner different from the forger owner), then N real forges.
        //    Each forge mints one gen-2 entity, so generationMintCounts[2] grows
        //    to N while currentGeneration stays 1.
        _distributeAndForge(w, c, n);
        assertEq(nft.generationMintCounts(2), n, "gen-2 pre-fill came from N real forges");
        assertEq(nft.totalSupply(), gen1Supply + n, "forged gen-2 tokens exist");
        assertEq(nft.currentGeneration(), 1, "forging into gen 2 did not roll generation");

        // 4) Injected precondition: generation 1 is full, so the next public mint
        //    rolls over. Everything the PoC asserts about gen 2 was produced by
        //    the real forge path above.
        _setGenMintCount(1, nft.maxTokensPerGen());
        // _tokenIds was already incremented once per real mint/forge, so it
        // equals totalSupply(). Persist exactly that value (instead of the old
        // made-up 500) so no phantom, non-existent tokens are introduced.
        uint256 liveSupply = nft.totalSupply();
        _setTokenIds(liveSupply);

        uint256 preFilled = nft.generationMintCounts(2);
        assertEq(preFilled, n, "pre-fill still intact before the rollover");
        uint256 price = nft.calculateMintPrice(); // maxed-out generation-1 price
        assertEq(price, 0.25 ether, "old-generation price quoted for the rollover mint");

        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);

        uint256 afterCount = nft.generationMintCounts(2);
        uint256 rolloverTokenId = liveSupply + 1;
        console.log("P3 forger entropy / potential     :", c.forgerEntropy, c.forgerPotential);
        console.log("P3 gen-2 entities forged (N)      :", preFilled);
        console.log("P3 generation after rollover      :", nft.currentGeneration());
        console.log("P3 generationMintCounts[2] after  :", afterCount);
        console.log("P3 correct value would be (N+1)   :", preFilled + 1);
        console.log("P3 rollover token generation      :", nft.getTokenGeneration(rolloverTokenId));

        assertEq(nft.currentGeneration(), 2, "rollover happened");
        assertEq(nft.getTokenGeneration(rolloverTokenId), 2, "new token belongs to generation 2");
        // Bug: the N forged entities were erased; a fixed contract keeps them
        // and would report N + 1 here.
        assertEq(afterCount, 1, "generationMintCounts[2] was reset, erasing N entities (correct value is N+1)");
        assertLt(afterCount, preFilled, "pre-filled generation count was destroyed");
        // Remaining capacity is 9999 instead of the intended 10000 - (N+1).
        assertEq(nft.maxTokensPerGen() - afterCount, 9999);
    }

    // ------------------------------------------------------------------ P4

    /// @dev P4 — no upper bound on generations: minting calls
    ///      _incrementGeneration with only the "full" check; the
    ///      `newGeneration <= maxGeneration` guard exists only in forge L166.
    ///
    ///      Injected state: a complete generation 10. Reaching it through real
    ///      mints would take ~100,000 mints (~1,275 ETH), which is not practical
    ///      at unit-test scale, so currentGeneration and generationMintCounts[10]
    ///      are written with vm.store and this is stated rather than pretended.
    ///      _tokenIds is deliberately NOT touched: it stays 0, matching the zero
    ///      tokens that actually exist, so no phantom supply is fabricated.
    function test_PoC_P4_generationExceedsMaxGeneration() public {
        _useRealWiring(true);
        assertEq(nft.maxGeneration(), 10, "maxGeneration default");
        _setCurrentGeneration(10);
        _setGenMintCount(10, nft.maxTokensPerGen());

        uint256 price = nft.calculateMintPrice();
        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);

        uint256 gen = nft.currentGeneration();
        console.log("P4 maxGeneration            :", nft.maxGeneration());
        console.log("P4 currentGeneration after  :", gen);
        console.log("P4 totalSupply              :", nft.totalSupply());
        console.log("P4 minted token generation  :", nft.getTokenGeneration(1));

        assertEq(gen, 11, "generation advanced past maxGeneration");
        assertEq(gen, nft.maxGeneration() + 1, "mint bypassed the maxGeneration cap");
        assertEq(nft.totalSupply(), 1, "mint succeeded at generation 11");
        assertEq(nft.getTokenGeneration(1), 11, "token was minted in generation 11");
    }

    // ------------------------------------------------------------------ P6

    /// @dev P6 — mintToken L190 computes the price from the OLD generation's
    ///      mint count, then _mintInternal L281-283 rolls the generation over
    ///      (resetting the count to 0 and raising priceIncrement). The buyer is
    ///      charged the maxed-out old price for a first-of-generation token.
    ///
    ///      Injected state: generation 1 is full so this mint rolls over. That
    ///      would take 10,000 real mints, so only generationMintCounts[1] is
    ///      written with vm.store; currentGeneration stays 1 and _tokenIds is
    ///      left at 0, matching the zero tokens in existence before the mint.
    function test_PoC_P6_priceOverchargeAtGenerationRollover() public {
        _useRealWiring(true);
        _setGenMintCount(1, nft.maxTokensPerGen());

        uint256 oldGenPrice = nft.calculateMintPrice(); // 0.005 + 0.0000245*10000
        console.log("P6 quoted price before mint (wei):", oldGenPrice);

        uint256 nukeBefore = NUKE.balance;
        uint256 userBefore = USER.balance;
        vm.prank(USER);
        nft.mintToken{value: oldGenPrice}(emptyProof);
        uint256 charged = NUKE.balance - nukeBefore;
        uint256 spent = userBefore - USER.balance;

        uint256 correctPrice = nft.startPrice(); // first mint of the new generation
        console.log("P6 charged (forwarded to nuke)   :", charged);
        console.log("P6 minted token generation       :", nft.getTokenGeneration(1));
        console.log("P6 correct new-generation price  :", correctPrice);
        console.log("P6 overcharge                    :", charged - correctPrice);
        console.log("P6 priceIncrement after rollover :", nft.priceIncrement());

        assertEq(nft.getTokenGeneration(1), 2, "token is a generation-2 token");
        // A fixed implementation would charge the new-generation price. Assert the harm,
        // not just the treasury receipt: a half-fix that still takes 0.25 from the buyer but
        // forwards 0.005 would satisfy the second assertion alone.
        assertEq(spent, 0.25 ether, "buyer net spend is the maxed-out generation-1 price");
        assertEq(charged, 0.25 ether, "the whole payment reached the treasury");
        assertEq(charged - correctPrice, 0.245 ether, "overcharge is 0.245 ETH");
        assertGt(charged, correctPrice, "charged price exceeds the correct price");
        assertEq(nft.calculateMintPrice(), 0.0050295 ether, "price right after rollover");
    }

    // ------------------------------------------------------------------ P7

    /// @dev P7 — burn L146-149 debits `initialOwners[tokenId]`, which is only
    ///      written at mint time (L294/L329) and never updated on transfer.
    ///      After a sale, burning charges the original minter's airdrop
    ///      allocation, not the current owner's.
    ///
    ///      P7 deliberately keeps MockEntropyGenerator: it needs a CHOSEN
    ///      entropy value (12_346) so the burn debit can be tied to a known
    ///      token entropy. The real generator's values are fixed by the seeded
    ///      slots, not selectable, which is unnecessary coupling for this PoC.
    function test_PoC_P7_burnDebitsOriginalMinter() public {
        vm.deal(ALICE, 10 ether);
        entropy.setCounter(12_345); // next minted token gets entropy 12_346

        uint256 price = nft.calculateMintPrice();
        vm.prank(ALICE);
        nft.mintToken{value: price}(emptyProof);

        uint256 tokenId = 1;
        uint256 tokenEntropy = nft.getTokenEntropy(tokenId);
        assertEq(nft.ownerOf(tokenId), ALICE);
        assertEq(nft.initialOwners(tokenId), ALICE);

        // Alice sells the token to RECEIVER; initialOwners is NOT updated.
        vm.prank(ALICE);
        nft.transferFrom(ALICE, RECEIVER, tokenId);
        assertEq(nft.ownerOf(tokenId), RECEIVER);
        assertEq(nft.initialOwners(tokenId), ALICE, "initialOwners still points at Alice");

        airdrop.setStarted(false); // make burn take the subUserAmount branch
        vm.prank(RECEIVER);
        nft.burn(tokenId);

        console.log("P7 token entropy               :", tokenEntropy);
        console.log("P7 amount debited from ALICE   :", airdrop.lastDebited(ALICE));
        console.log("P7 amount debited from RECEIVER:", airdrop.lastDebited(RECEIVER));
        console.log("P7 debited user is original minter:", airdrop.lastDebitedUser() == ALICE);
        console.log("P7 subUserAmount calls         :", airdrop.subCallCount());

        assertEq(nft.totalSupply(), 0, "token was burned");
        assertEq(nft.balanceOf(RECEIVER), 0);
        assertEq(airdrop.subCallCount(), 1, "burn performed exactly one debit");
        assertEq(airdrop.lastDebitedUser(), ALICE, "burn debited the original minter");
        assertEq(airdrop.lastDebited(ALICE), tokenEntropy, "Alice's allocation was charged");
        assertEq(airdrop.lastDebited(RECEIVER), 0, "current owner was not charged");
    }

    // ------------------------------------------------------------------ P8

    /// @dev P8 — TraitForgeNft inherits OZ Pausable but exposes no pause()/
    ///      unpause() wrapper; `_pause` is internal and there is no fallback,
    ///      so the emergency stop is unreachable even for the owner.
    ///      Kept on the mock wiring: the finding is purely about the ABI surface.
    function test_PoC_P8_pauseUnreachable() public {
        assertEq(nft.owner(), address(this), "test contract is the owner");

        bool pausedBefore = nft.paused();
        (bool okPause, ) = address(nft).call(abi.encodeWithSignature("pause()"));
        (bool okUnpause, ) = address(nft).call(abi.encodeWithSignature("unpause()"));
        bool pausedAfter = nft.paused();

        console.log("P8 paused() before          :", pausedBefore);
        console.log("P8 pause() call succeeded   :", okPause);
        console.log("P8 unpause() call succeeded :", okUnpause);
        console.log("P8 paused() after           :", pausedAfter);

        assertFalse(pausedBefore, "contract starts unpaused");
        assertFalse(okPause, "pause() is reachable from outside");
        assertFalse(okUnpause, "unpause() is reachable from outside");
        assertFalse(pausedAfter, "paused() state can be changed");
    }

    // ------------------------------------------------------------------ P9

    /// @dev P9 — setNukeFundContract L66-71 has no zero-address check.
    ///      _distributeFunds L361 then does a low-level call to address(0),
    ///      which succeeds and burns the mint payment instead of reverting.
    ///      Kept on the mock wiring because only the test contract (owner there)
    ///      can call the onlyOwner setter.
    function test_PoC_P9_zeroTreasuryBurnsFunds() public {
        nft.setNukeFundContract(payable(address(0))); // accepted: no validation
        assertEq(nft.nukeFundAddress(), address(0));

        uint256 price = nft.calculateMintPrice();
        uint256 userBefore = USER.balance;
        uint256 burnedBefore = address(0).balance;

        vm.prank(USER);
        nft.mintToken{value: price}(emptyProof);

        uint256 burned = address(0).balance - burnedBefore;
        console.log("P9 nukeFundAddress           :", nft.nukeFundAddress());
        console.log("P9 mint price sent (wei)     :", price);
        console.log("P9 NFT contract balance      :", address(nft).balance);
        console.log("P9 ETH burned at address(0)  :", burned);
        console.log("P9 totalSupply               :", nft.totalSupply());

        assertEq(nft.totalSupply(), 1, "mint succeeded against a zero treasury");
        assertEq(nft.ownerOf(1), USER, "minter received the token");
        assertEq(address(nft).balance, 0, "no ETH is stuck in the NFT contract");
        assertEq(burned, price, "the mint payment was burned at address(0)");
        assertEq(USER.balance, userBefore - price, "buyer paid and the ETH is unrecoverable");
    }

    // ------------------------------------------------------------------ P10

    /// @dev P10 — F-10: generation rollover is unreachable unless the NFT owns the
    ///      entropy generator. The generator is deployed separately and
    ///      TraitForgeNft._incrementGeneration() calls initializeAlphaIndices(),
    ///      which is onlyOwner. The NFT is not the owner, so every mint that
    ///      triggers a rollover reverts and the collection stops at 10,000 tokens.
    ///
    ///      Same real wiring as P3 but with the ownership transfer omitted; the
    ///      "generation 1 is full" precondition is injected exactly as in P3
    ///      (real 10,000 mints are impractical at unit-test scale) and _tokenIds
    ///      stays 0, matching the zero tokens that exist.
    function test_PoC_P10_rolloverRevertsWithoutOwnershipTransfer() public {
        RealWiring w = _useRealWiring(false);
        assertEq(w.entropy().owner(), address(w), "entropy ownership was NOT handed to the NFT");
        assertEq(w.entropy().getAllowedCaller(), address(nft), "NFT is still the allowed entropy caller");

        _setGenMintCount(1, nft.maxTokensPerGen());
        uint256 price = nft.calculateMintPrice();
        assertEq(price, 0.25 ether, "maxed-out generation-1 price");

        vm.prank(USER);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        nft.mintToken{value: price}(emptyProof);

        console.log("P10 generationMintCounts[1]     :", nft.generationMintCounts(1));
        console.log("P10 currentGeneration after     :", nft.currentGeneration());
        console.log("P10 rollover-triggering mint    : reverted (entropy not owned by NFT)");
        assertEq(nft.currentGeneration(), 1, "rollover reverted; generation unchanged");
        assertEq(nft.generationMintCounts(2), 0, "no generation-2 state was written");
        assertEq(nft.totalSupply(), 0, "no token was minted");
    }

    /// @dev P11 — F-10, second half: the only way to make the rollover work is to
    ///      give the generator away, and that transfer is irreversible in
    ///      practice. Once the NFT owns the generator, no external account can
    ///      call any onlyOwner function on it any more — role rotation
    ///      (setAllowedCaller), the pause() from F-08, and initializeAlphaIndices
    ///      itself included. There is no admin left on a contract that still
    ///      mediates every mint.
    ///
    ///      The test first shows the DoS (leg 1), then performs the transfer and
    ///      shows the loss of control (leg 2).
    function test_PoC_P11_ownershipTransferStrandsEntropyAdmin() public {
        RealWiring w = _useRealWiring(false);
        EntropyGenerator gen = w.entropy();

        // Leg 1: rollover is blocked while the deployer keeps ownership.
        _setGenMintCount(1, nft.maxTokensPerGen());
        uint256 price = nft.calculateMintPrice();
        vm.prank(USER);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        nft.mintToken{value: price}(emptyProof);

        // Leg 2: hand the generator to the NFT so the rollover works ...
        // (RealWiring deployed the generator, so it is the current owner.)
        vm.prank(address(w));
        gen.transferOwnership(address(nft));
        assertEq(gen.owner(), address(nft), "generator owner is now the NFT contract");
        assertEq(gen.getAllowedCaller(), address(nft), "NFT was already the allowed caller");

        // ... and the deployer has no administrative access left.
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        gen.setAllowedCaller(address(this));

        console.log("P11 entropy owner after transfer:", gen.owner());
        console.log("P11 setAllowedCaller callable   : no (Ownable: caller is not the owner)");
        assertTrue(gen.owner() != address(this), "no external account owns the generator");
    }
}
