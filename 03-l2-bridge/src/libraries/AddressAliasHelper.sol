// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice OP Stack address aliasing. When a contract on L1 calls a contract on L2 through the
///         messenger, the L2 side sees `msg.sender` shifted by a fixed offset. Any L2 contract that
///         authorises an L1 address must undo the alias first; forgetting this is a recurring source
///         of "the wrong account is trusted" bugs.
library AddressAliasHelper {
    uint160 internal constant OFFSET = uint160(0x1111000000000000000000000000000000001111);

    /// @notice L1 address -> address seen by the L2 contract.
    function applyL1ToL2Alias(address l1Address) internal pure returns (address) {
        unchecked {
            return address(uint160(l1Address) + OFFSET);
        }
    }

    /// @notice Address seen on L2 -> original L1 address. Only meaningful for aliased senders.
    function undoL1ToL2Alias(address l2Address) internal pure returns (address) {
        unchecked {
            return address(uint160(l2Address) - OFFSET);
        }
    }
}
