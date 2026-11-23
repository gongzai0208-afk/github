// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {TraitForgeNft} from "traitforge/TraitForgeNft/TraitForgeNft.sol";
import {EntropyGenerator} from "traitforge/EntropyGenerator/EntropyGenerator.sol";
import {EntityForging} from "traitforge/EntityForging/EntityForging.sol";
import {MockAirdrop} from "../mocks/SharedMocks.sol";

/// @title RealWiring
/// @notice Helper contract (not a test) that deploys and wires the real,
///         in-scope TraitForge contracts so PoCs can exercise the real mint and
///         forging paths instead of hand-written mocks.
///
/// @dev Ordering is deliberate:
///      1. deploy TraitForgeNft;
///      2. deploy the real EntropyGenerator against it (constructor sets
///         `allowedCaller = nft` and calls initializeAlphaIndices() once);
///      3. fill all 770 entropy slots and re-run the alpha index selection while
///         the deployer still owns the generator (writeEntropyBatch1/2/3 are
///         public one-shots, initializeAlphaIndices() is onlyOwner);
///      4. deploy EntityForging against the NFT and configure it;
///      5. point the NFT at the airdrop stub and the plain-address treasury;
///      6. LAST: transfer EntropyGenerator ownership to the NFT.
///         After step 6 the deployer can no longer call onlyOwner functions on
///         the generator. The shipped access control forces this: the NFT calls
///         `entropyGenerator.initializeAlphaIndices()` from
///         `_incrementGeneration()`, so omitting the transfer makes every
///         rollover-triggering mint revert (P10).
///
///         F-10 covers the other half of that trade-off: the transfer also
///         removes every external administrator from the generator (P11), which
///         is why the report recommends granting the NFT a caller role instead
///         and keeping ownership with a human. `transferEntropyOwnership = true`
///         models the deployment the shipped code requires, not the recommended
///         fix.
///
///      Stubbed: IAirdrop has no implementation in scope, so the existing
///      MockAirdrop is reused. It is configured "airdrop already started", which
///      makes the NFT skip the airdrop add/sub bookkeeping; the P3/P4/P6/P10
///      assertions do not depend on airdrop behaviour.
contract RealWiring {
    TraitForgeNft public immutable nft;
    EntropyGenerator public immutable entropy;
    EntityForging public immutable forging;
    MockAirdrop public immutable airdrop;
    address payable public immutable nukeFund;

    constructor(address payable nukeFund_, bool transferEntropyOwnership) {
        require(nukeFund_ != address(0), "RealWiring: treasury required");
        nukeFund = nukeFund_;

        nft = new TraitForgeNft();

        // The real generator is deployed against the NFT, so the NFT is the only
        // address allowed to call getNextEntropy().
        entropy = new EntropyGenerator(address(nft));

        // One-shot entropy initialisation. These three functions have no owner
        // check but cannot be repeated; initializeAlphaIndices() is onlyOwner.
        entropy.writeEntropyBatch1();
        entropy.writeEntropyBatch2();
        entropy.writeEntropyBatch3();
        entropy.initializeAlphaIndices();
        // Sanity: all slots were filled and none of the writes was skipped.
        require(entropy.getLastInitializedIndex() == 770, "RealWiring: entropy not initialised");

        // IAirdrop is out of scope (no implementation in src/), so the local
        // stub is kept. Defaults to "airdrop started", which keeps the NFT's
        // mint/burn airdrop bookkeeping out of the way.
        airdrop = new MockAirdrop();

        forging = new EntityForging(address(nft));
        forging.setNukeFundAddress(nukeFund_);

        nft.setAirdropContract(address(airdrop));
        nft.setEntityForgingContract(address(forging));
        nft.setEntropyGenerator(address(entropy));
        nft.setNukeFundContract(nukeFund_);
        nft.setWhitelistEndTime(0); // whitelist disabled: empty merkle proof accepted

        // LAST owner-only handover. See the contract-level note above.
        if (transferEntropyOwnership) {
            entropy.transferOwnership(address(nft));
        }
    }

    /// @dev Entropy value the `index`-th mintToken() call will receive, assuming
    ///      every mint goes through the NFT (getNextEntropy() walks 13 numbers
    ///      per slot, then advances the slot). Forging does not consume the
    ///      stream, so this is only valid for public mints.
    function entropyAt(uint256 index) external view returns (uint256) {
        return entropy.getPublicEntropy(index / 13, index % 13);
    }
}
