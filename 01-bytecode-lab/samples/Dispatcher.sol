// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Sample target for the bytecode lab. Small enough to read by hand, large enough to have
///         two dispatcher guards, a storage-heavy setter and an unguarded function. The runtime
///         bytecode in `Dispatcher.bin` is built from this file with the command in README.md.
contract Dispatcher {
    address public owner;
    uint256 public value;
    mapping(address => bool) public allowed;

    constructor() {
        owner = msg.sender;
    }

    function setValue(uint256 newValue) external {
        require(msg.sender == owner, "OWNER");
        value = newValue;
    }

    function allow(address who) external {
        require(msg.sender == owner, "OWNER");
        allowed[who] = true;
    }

    function poke() external {
        value = value + 1;
    }
}
