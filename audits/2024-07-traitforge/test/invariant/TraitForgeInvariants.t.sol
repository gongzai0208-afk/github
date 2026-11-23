// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {TraitForgeNft} from "traitforge/TraitForgeNft/TraitForgeNft.sol";
import {MockAirdrop, MockEntropyGenerator, MockForgingRegistry} from "../mocks/SharedMocks.sol";

/// @dev Drives public mint and budget mint at random. Forging is left out on
///      purpose: it needs a forger/merger pair whose entropy the light fixture
///      cannot choose freely, and the invariants below do not depend on it.
contract MintHandler is Test {
    TraitForgeNft public nft;

    address[2] public actors = [address(0xB0B), address(0xB0B0)];

    constructor(TraitForgeNft nft_) {
        nft = nft_;
        for (uint256 i = 0; i < 2; i++) {
            vm.deal(actors[i], 1_000 ether);
        }
    }

    function mint(uint256 actorSeed) external {
        address actor = actors[actorSeed % 2];
        uint256 price = nft.calculateMintPrice();
        if (actor.balance < price) return;
        vm.prank(actor);
        try nft.mintToken{value: price}(new bytes32[](0)) {} catch {}
    }

    function mintWithBudget(uint256 actorSeed, uint256 value) external {
        address actor = actors[actorSeed % 2];
        value = bound(value, 0, 2 ether);
        if (actor.balance < value) return;
        vm.prank(actor);
        try nft.mintWithBudget{value: value}(new bytes32[](0)) {} catch {}
    }
}

/// @notice Invariant suite for TraitForgeNft (run with `FOUNDRY_PROFILE=invariant`).
/// @dev These hold on both the reviewed code and the fixed tree; they are
///      regression nets, not the PoCs:
///        1. the NFT contract never keeps mint payments (excess is refunded);
///        2. a generation can never hold more than `maxTokensPerGen`;
///        3. the generation counter never passes `maxGeneration`.
///      (3) is weak on the reviewed code: the missing bound is only reachable
///      after 100,000 mints, which a fuzz run does not reach — PoC P4 is what
///      demonstrates it.
contract TraitForgeInvariants is Test {
    TraitForgeNft nft;
    MockAirdrop airdrop;
    MockEntropyGenerator entropy;
    MockForgingRegistry registry;
    MintHandler handler;

    function setUp() public {
        nft = new TraitForgeNft();
        airdrop = new MockAirdrop();
        entropy = new MockEntropyGenerator();
        registry = new MockForgingRegistry();
        nft.setAirdropContract(address(airdrop));
        nft.setEntropyGenerator(address(entropy));
        nft.setEntityForgingContract(address(registry));
        nft.setNukeFundContract(payable(address(0xBEEF)));
        nft.setWhitelistEndTime(0);
        handler = new MintHandler(nft);
        targetContract(address(handler));
    }

    function invariant_contractHoldsNoEth() public view {
        assertEq(address(nft).balance, 0, "mint payments are forwarded or refunded");
    }

    function invariant_generationStaysWithinCap() public view {
        assertLe(
            nft.generationMintCounts(nft.currentGeneration()),
            nft.maxTokensPerGen(),
            "current generation never exceeds its cap"
        );
    }

    function invariant_generationWithinMax() public view {
        assertLe(nft.currentGeneration(), nft.maxGeneration(), "generation counter within max");
    }
}
