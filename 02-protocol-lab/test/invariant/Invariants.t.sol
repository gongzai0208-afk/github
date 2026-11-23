// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {InterestModel} from "../../src/InterestModel.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeed, MockSequencer} from "../mocks/MockFeeds.sol";
import {Handler} from "./Handler.sol";

contract InvariantsTest is Test {
    MockERC20 asset;
    MockERC20 weth;
    MockFeed feed;
    MockSequencer sequencer;
    TwapOracle oracle;
    InterestModel model;
    LendingPool pool;
    Handler handler;

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockERC20("USD", "USD", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockFeed();
        sequencer = new MockSequencer();
        sequencer.set(0, block.timestamp - 1 days);

        oracle = new TwapOracle(address(this), address(this), feed, sequencer, 1800, 3600, 3600, 0.05e18, 1800);
        model = new InterestModel(0, 0.05e18, 0.5e18, 0.8e18);
        pool = new LendingPool(asset, weth, oracle, model, address(this));

        feed.set(2000e8, block.timestamp);
        oracle.pushPrice(2000e18);
        vm.warp(block.timestamp + 1800);
        feed.set(2000e8, block.timestamp);
        oracle.pushPrice(2000e18);

        asset.mint(address(this), 1_000_000e18);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e18, address(this));

        handler = new Handler(pool, asset, weth, oracle, feed, 2000e18);
        // The handler is the only actor allowed to push prices; without this every setPrice/warp
        // reverts and the campaign never moves time or price.
        oracle.setFeeder(address(handler));
        targetContract(address(handler));
    }

    function _actors() internal view returns (address[] memory) {
        address[] memory list = new address[](handler.actorCount());
        for (uint256 i = 0; i < list.length; i++) {
            list[i] = handler.actors(i);
        }
        return list;
    }

    function invariant_totalAssetsIsIdlePlusDebt() public view {
        assertEq(pool.totalAssets(), asset.balanceOf(address(pool)) + pool.totalDebt());
    }

    function invariant_sharesSumToSupply() public view {
        address[] memory list = _actors();
        uint256 sum = pool.balanceOf(address(this));
        for (uint256 i = 0; i < list.length; i++) {
            sum += pool.balanceOf(list[i]);
        }
        assertEq(sum, pool.totalSupply());
    }

    function invariant_collateralIsBacked() public view {
        address[] memory list = _actors();
        uint256 sum;
        for (uint256 i = 0; i < list.length; i++) {
            sum += pool.collateralOf(list[i]);
        }
        assertGe(weth.balanceOf(address(pool)), sum);
    }

    function invariant_userDebtDoesNotExceedPoolDebt() public view {
        address[] memory list = _actors();
        uint256 sum;
        for (uint256 i = 0; i < list.length; i++) {
            sum += pool.debtOf(list[i]);
        }
        // Debt is shares-based, so the floor per position cannot exceed the pool total.
        assertLe(sum, pool.totalDebt());
    }

    function invariant_borrowIndexNeverFalls() public view {
        assertGe(pool.borrowIndex(), 1e18);
    }
}
