// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockFeed, MockSequencer} from "./mocks/MockFeeds.sol";

contract TwapOracleTest is Test {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    MockFeed feed;
    MockSequencer sequencer;
    TwapOracle oracle;

    uint256 constant PRICE = 2000e18;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockFeed();
        sequencer = new MockSequencer();
        sequencer.set(0, block.timestamp - 1 days);
        oracle = new TwapOracle(address(this), address(this), feed, sequencer, 1800, 3600, 3600, 0.05e18, 1800);
        _prime(PRICE);
    }

    function _prime(uint256 price) internal {
        feed.set(int256(price / 1e10), block.timestamp);
        oracle.pushPrice(price);
        vm.warp(block.timestamp + 1800);
        feed.set(int256(price / 1e10), block.timestamp);
        oracle.pushPrice(price);
    }

    function test_scales_eight_decimal_feed() public view {
        assertEq(oracle.price(), PRICE);
    }

    function test_twap_follows_new_price_after_window() public {
        vm.warp(block.timestamp + 1800);
        feed.set(int256(uint256(1000e18) / 1e10), block.timestamp);
        oracle.pushPrice(1000e18);
        vm.warp(block.timestamp + 1800);
        feed.set(int256(uint256(1000e18) / 1e10), block.timestamp);
        oracle.pushPrice(1000e18);
        assertEq(oracle.price(), 1000e18);
    }

    function test_only_feeder_can_push() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("NOT_FEEDER"));
        oracle.pushPrice(PRICE);
    }

    function test_stale_twap_reverts() public {
        vm.warp(block.timestamp + 4000);
        vm.expectRevert(bytes("STALE"));
        oracle.twap();
    }

    function test_feed_staleness_reverts() public {
        feed.set(int256(PRICE / 1e10), block.timestamp - 4000);
        vm.expectRevert(bytes("FEED_STALE"));
        oracle.price();
    }

    function test_deviation_reverts() public {
        feed.set(int256(uint256(3000e18) / 1e10), block.timestamp);
        vm.expectRevert(bytes("DEVIATION"));
        oracle.price();
    }

    function test_sequencer_down_reverts() public {
        sequencer.set(1, block.timestamp);
        vm.expectRevert(bytes("SEQUENCER_DOWN"));
        oracle.price();
    }

    function test_sequencer_grace_period_reverts() public {
        sequencer.set(0, block.timestamp);
        vm.expectRevert(bytes("SEQUENCER_GRACE"));
        oracle.price();
    }

    function test_twap_without_history_reverts() public {
        TwapOracle fresh = new TwapOracle(address(this), address(this), feed, sequencer, 1800, 3600, 3600, 0.05e18, 1800);
        fresh.pushPrice(PRICE);
        vm.warp(block.timestamp + 100);
        vm.expectRevert(bytes("NO_HISTORY"));
        fresh.twap();
    }

    function test_zero_feeder_is_rejected() public {
        vm.expectRevert(bytes("FEEDER"));
        new TwapOracle(address(this), address(0), feed, sequencer, 1800, 3600, 3600, 0.05e18, 1800);
    }

    function test_transfer_ownership_emits_event() public {
        address next = address(0xBEEF);
        vm.expectEmit(true, true, false, false, address(oracle));
        emit OwnershipTransferred(address(this), next);
        oracle.transferOwnership(next);
        assertEq(oracle.owner(), next);
    }
}
