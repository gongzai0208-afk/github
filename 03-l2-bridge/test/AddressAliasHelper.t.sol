// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {AddressAliasHelper} from "../src/libraries/AddressAliasHelper.sol";

contract AddressAliasHelperTest is Test {
    function test_known_vector() public pure {
        // The canonical example: 0x...0001 becomes 0x1111...1112.
        assertEq(
            AddressAliasHelper.applyL1ToL2Alias(address(uint160(1))),
            address(uint160(0x1111000000000000000000000000000000001112))
        );
    }

    function test_roundtrip_fuzz(address l1Address) public pure {
        address aliased = AddressAliasHelper.applyL1ToL2Alias(l1Address);
        assertEq(AddressAliasHelper.undoL1ToL2Alias(aliased), l1Address);
    }

    function test_alias_is_additive_not_xor() public pure {
        address a = address(uint160(0x1111000000000000000000000000000000001111));
        // Aliasing the offset itself doubles it; an XOR-based implementation would return zero.
        assertEq(
            AddressAliasHelper.applyL1ToL2Alias(a),
            address(uint160(0x2222000000000000000000000000000000002222))
        );
    }

    function test_wraps_modulo_160_bits() public pure {
        address max = address(type(uint160).max);
        // max + 0x1111...1111 modulo 2^160; checked arithmetic in the test would overflow first.
        assertEq(
            AddressAliasHelper.applyL1ToL2Alias(max),
            address(uint160(0x1111000000000000000000000000000000001110))
        );
    }

    function test_undo_of_non_aliased_address_is_offset() public pure {
        // Documents the trap: undoing a normal address produces a different address, so a contract
        // must only unalias when the caller really came through the messenger.
        address normal = address(uint160(0x1234));
        assertTrue(AddressAliasHelper.undoL1ToL2Alias(normal) != normal);
    }
}
