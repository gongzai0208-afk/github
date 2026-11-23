// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IEntityForging} from "traitforge/EntityForging/IEntityForging.sol";

/// @dev Minimal NFT standing in for TraitForgeNft on the EntityForging side.
///      Only the selectors EntityForging actually calls are implemented.
///      Entropy/owner/generation are fully controllable so the forge-path
///      preconditions (forger==entropy%3==0, merger!=0, same generation) can
///      be satisfied deterministically.
contract MockNftForForging {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => uint256) private _entropy;
    mapping(uint256 => uint256) private _generation;
    uint256 public nextTokenId = 1000;

    function setToken(
        uint256 tokenId,
        address owner,
        uint256 entropy,
        uint256 generation
    ) external {
        _owners[tokenId] = owner;
        _entropy[tokenId] = entropy;
        _generation[tokenId] = generation;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }

    function getTokenEntropy(uint256 tokenId) external view returns (uint256) {
        return _entropy[tokenId];
    }

    function getTokenGeneration(uint256 tokenId) external view returns (uint256) {
        return _generation[tokenId];
    }

    /// @dev Called by EntityForging; mints the offspring to `newOwner`.
    function forge(
        address newOwner,
        uint256 parent1Id,
        uint256 parent2Id,
        string memory
    ) external returns (uint256) {
        uint256 newId = ++nextTokenId;
        _owners[newId] = newOwner;
        _entropy[newId] = (_entropy[parent1Id] + _entropy[parent2Id]) / 2;
        _generation[newId] = _generation[parent1Id] + 1;
        return newId;
    }
}

/// @dev Minimal forging-registry mock used by TraitForgeNft._beforeTokenTransfer.
///      Always reports "not listed", so mint/transfer never cancels a listing.
contract MockForgingRegistry {
    function getListedTokenIds(uint256) external pure returns (uint256) {
        return 0;
    }

    function getListings(uint256) external pure returns (IEntityForging.Listing memory) {
        return IEntityForging.Listing(address(0), 0, false, 0);
    }

    function cancelListingForForging(uint256) external {}
}

/// @dev Airdrop stub. Defaults to "airdrop already started" so
///      TraitForgeNft skips add/sub bookkeeping; P7 flips `started` to false
///      and records exactly who `burn` debits.
contract MockAirdrop {
    bool public started = true;

    mapping(address => uint256) public lastDebited;
    address public lastDebitedUser;
    uint256 public subCallCount;

    function setStarted(bool value) external {
        started = value;
    }

    function airdropStarted() external view returns (bool) {
        return started;
    }

    function addUserAmount(address, uint256) external {}

    function subUserAmount(address user, uint256 amount) external {
        lastDebited[user] += amount;
        lastDebitedUser = user;
        subCallCount++;
    }

    function startAirdrop(uint256) external {}
}

/// @dev Entropy stub: monotonically increasing entropy, generation rollover
///      hook is a no-op.
contract MockEntropyGenerator {
    uint256 public counter;

    function setCounter(uint256 value) external {
        counter = value;
    }

    function getNextEntropy() external returns (uint256) {
        return ++counter;
    }

    function initializeAlphaIndices() external {}
}
