// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeed} from "../mocks/MockFeeds.sol";

/// @notice Drives the pool through real entry points only. Every action is bounded and wrapped in
///         try/catch so a revert is a skipped path, not a broken campaign.
contract Handler is Test {
    LendingPool public pool;
    MockERC20 public asset;
    MockERC20 public collateral;
    TwapOracle public oracle;
    MockFeed public feed;

    address[] public actors;
    uint256 public currentPrice;

    constructor(
        LendingPool pool_,
        MockERC20 asset_,
        MockERC20 collateral_,
        TwapOracle oracle_,
        MockFeed feed_,
        uint256 price_
    ) {
        pool = pool_;
        asset = asset_;
        collateral = collateral_;
        oracle = oracle_;
        feed = feed_;
        currentPrice = price_;

        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            asset.mint(actor, 1_000_000e18);
            collateral.mint(actor, 1_000e18);
            vm.startPrank(actor);
            asset.approve(address(pool), type(uint256).max);
            collateral.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        amount = bound(amount, 1, 50_000e18);
        vm.prank(actor);
        try pool.deposit(amount, actor) {} catch {}
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        uint256 max = pool.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(actor);
        try pool.withdraw(amount, actor, actor) {} catch {}
    }

    function addCollateral(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        amount = bound(amount, 1, 100e18);
        vm.prank(actor);
        try pool.depositCollateral(amount) {} catch {}
    }

    function removeCollateral(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        uint256 max = pool.collateralOf(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(actor);
        try pool.withdrawCollateral(amount) {} catch {}
    }

    function borrow(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        amount = bound(amount, 1, 20_000e18);
        vm.prank(actor);
        try pool.borrow(amount, actor) {} catch {}
    }

    function repay(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        uint256 debt = pool.debtOf(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        vm.prank(actor);
        try pool.repay(amount) {} catch {}
    }

    function liquidate(uint256 seed, uint256 amount) external {
        address actor = actors[seed % actors.length];
        if (!pool.isLiquidatable(actor)) return;
        address liquidator = address(0xF11);
        asset.mint(liquidator, amount);
        vm.startPrank(liquidator);
        asset.approve(address(pool), type(uint256).max);
        try pool.liquidate(actor, amount) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 60, 1800);
        vm.warp(block.timestamp + dt);
        feed.set(int256(currentPrice / 1e10), block.timestamp);
        oracle.pushPrice(currentPrice);
    }

    function setPrice(uint256 price) external {
        currentPrice = bound(price, 500e18, 3000e18);
        feed.set(int256(currentPrice / 1e10), block.timestamp);
        oracle.pushPrice(currentPrice);
    }
}
