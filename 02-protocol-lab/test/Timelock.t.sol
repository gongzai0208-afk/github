// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Timelock} from "../src/Timelock.sol";

contract Target {
    uint256 public value;

    function set(uint256 value_) external {
        value = value_;
    }
}

contract TimelockTest is Test {
    Timelock timelock;
    Target target;

    function setUp() public {
        vm.warp(1_000_000);
        timelock = new Timelock(address(this), 1 days);
        target = new Target();
    }

    function test_execute_before_delay_reverts() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        bytes32 id = timelock.queue(address(target), 0, data);

        vm.expectRevert(bytes("TOO_EARLY"));
        timelock.execute(id, address(target), 0, data);
    }

    function test_execute_after_delay_changes_state() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        bytes32 id = timelock.queue(address(target), 0, data);

        vm.warp(block.timestamp + 1 days);
        timelock.execute(id, address(target), 0, data);
        assertEq(target.value(), 7);
    }

    function test_execute_twice_reverts() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        bytes32 id = timelock.queue(address(target), 0, data);
        vm.warp(block.timestamp + 1 days);
        timelock.execute(id, address(target), 0, data);

        vm.expectRevert(bytes("UNKNOWN"));
        timelock.execute(id, address(target), 0, data);
    }

    function test_cancel_prevents_execution() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        bytes32 id = timelock.queue(address(target), 0, data);
        timelock.cancel(id);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(bytes("UNKNOWN"));
        timelock.execute(id, address(target), 0, data);
    }

    function test_only_owner_can_queue() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("NOT_OWNER"));
        timelock.queue(address(target), 0, data);
    }

    function test_two_step_ownership() public {
        address next = address(0xBEEF);
        timelock.transferOwnership(next);
        assertEq(timelock.owner(), address(this));

        vm.prank(next);
        timelock.acceptOwnership();
        assertEq(timelock.owner(), next);
    }

    function test_delay_cannot_be_below_one_hour() public {
        vm.expectRevert(bytes("DELAY_TOO_SHORT"));
        new Timelock(address(this), 59 minutes);
    }

    function test_execute_rejects_zero_target() public {
        bytes32 id = timelock.queue(address(0), 0, "");
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(bytes("TARGET"));
        timelock.execute(id, address(0), 0, "");
    }
}
