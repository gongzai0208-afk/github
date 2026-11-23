// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {InterestModel} from "../src/InterestModel.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {Timelock} from "../src/Timelock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeed, MockSequencer} from "./mocks/MockFeeds.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract LendingPoolTest is Test {
    MockERC20 asset;
    MockERC20 weth;
    MockFeed feed;
    MockSequencer sequencer;
    TwapOracle oracle;
    InterestModel model;
    LendingPool pool;

    address lp = address(0xA11CE);
    address borrower = address(0xB0B);
    address liquidator = address(0xC0FFEE);

    uint256 constant PRICE = 2000e18;

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockERC20("USD", "USD", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockFeed();
        sequencer = new MockSequencer();
        sequencer.set(0, block.timestamp - 1 days);

        oracle = new TwapOracle(
            address(this),
            address(this),
            feed,
            sequencer,
            1800,
            3600,
            3600,
            0.05e18,
            1800
        );
        model = new InterestModel(0, 0.05e18, 0.5e18, 0.8e18);
        pool = new LendingPool(asset, weth, oracle, model, address(this));

        _prime(PRICE);

        asset.mint(lp, 1_000_000e18);
        vm.prank(lp);
        asset.approve(address(pool), type(uint256).max);
        vm.prank(lp);
        pool.deposit(100_000e18, lp);

        weth.mint(borrower, 10e18);
        vm.prank(borrower);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        pool.depositCollateral(10e18);
    }

    function _prime(uint256 price) internal {
        feed.set(int256(price / 1e10), block.timestamp);
        oracle.pushPrice(price);
        vm.warp(block.timestamp + 1800);
        feed.set(int256(price / 1e10), block.timestamp);
        oracle.pushPrice(price);
    }

    // ------------------------------------------------------------- 4626

    function test_deposit_and_redeem() public {
        uint256 before = asset.balanceOf(lp);
        uint256 initialShares = pool.balanceOf(lp);
        vm.prank(lp);
        uint256 shares = pool.deposit(10_000e18, lp);
        assertGt(shares, 0);
        assertEq(asset.balanceOf(lp), before - 10_000e18);

        vm.prank(lp);
        uint256 assets = pool.redeem(shares, lp, lp);
        assertApproxEqAbs(assets, 10_000e18, 1e6);
        assertEq(pool.balanceOf(lp), initialShares);
    }

    function test_withdraw_more_than_idle_reverts() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);

        vm.prank(lp);
        vm.expectRevert(bytes("ILLIQUID"));
        pool.withdraw(100_000e18, lp, lp);
    }

    function test_donation_does_not_steal_from_next_depositor() public {
        LendingPool fresh = new LendingPool(asset, weth, oracle, model, address(this));
        address attacker = address(0xBAD);
        address victim = address(0x71C7);
        asset.mint(attacker, 2e18);
        asset.mint(victim, 1e18);

        vm.prank(attacker);
        asset.approve(address(fresh), type(uint256).max);
        vm.prank(attacker);
        fresh.deposit(1, attacker);
        vm.prank(attacker);
        asset.transfer(address(fresh), 1e18);

        vm.prank(victim);
        asset.approve(address(fresh), type(uint256).max);
        vm.prank(victim);
        uint256 shares = fresh.deposit(1e18, victim);
        assertGt(shares, 0, "victim got no shares");
        // Virtual shares leave a rounding cost of a few parts per billion, not a loss to the donor.
        assertApproxEqRel(fresh.previewRedeem(shares), 1e18, 1e12, "victim lost value to the donation");
    }

    // ------------------------------------------------------------- borrow

    function test_borrow_respects_ltv() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);
        assertEq(asset.balanceOf(borrower), 15_000e18);

        vm.prank(borrower);
        vm.expectRevert(bytes("LTV"));
        pool.borrow(1e18, borrower);
    }

    function test_borrow_without_collateral_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("LTV"));
        pool.borrow(1e18, address(0xDEAD));
    }

    function test_interest_accrues_to_lenders() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);

        uint256 assetsBefore = pool.totalAssets();
        uint256 debtBefore = pool.debtOf(borrower);
        vm.warp(block.timestamp + 365 days);
        pool.accrue();

        assertGt(pool.debtOf(borrower), debtBefore);
        assertGt(pool.totalAssets(), assetsBefore);
    }

    // ------------------------------------------------------------- liquidation

    function test_liquidation_seizes_collateral_with_bonus() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);

        _prime(1500e18);
        asset.mint(liquidator, 20_000e18);
        vm.prank(liquidator);
        asset.approve(address(pool), type(uint256).max);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(borrower, 15_000e18);

        assertEq(pool.collateralOf(borrower), 0);
        assertEq(pool.debtOf(borrower), 0);
        assertEq(weth.balanceOf(liquidator) - liquidatorWethBefore, 10e18);
    }

    function test_bad_debt_is_written_off_and_share_price_drops() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);

        _prime(1000e18);
        uint256 priceBefore = pool.convertToAssets(1e18);

        asset.mint(liquidator, 20_000e18);
        vm.prank(liquidator);
        asset.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        pool.liquidate(borrower, type(uint256).max);

        assertEq(pool.collateralOf(borrower), 0);
        assertEq(pool.debtOf(borrower), 0);
        assertLt(pool.convertToAssets(1e18), priceBefore, "loss was not socialised");
    }

    function test_healthy_position_cannot_be_liquidated() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);

        vm.prank(liquidator);
        vm.expectRevert(bytes("HEALTHY"));
        pool.liquidate(borrower, 1e18);
    }

    function test_liquidation_reverts_when_the_pull_reports_failure() public {
        vm.prank(borrower);
        pool.borrow(15_000e18, borrower);
        _prime(1500e18);

        asset.mint(liquidator, 20_000e18);
        vm.prank(liquidator);
        asset.approve(address(pool), type(uint256).max);

        // A token that answers `false` instead of reverting: without the return check the
        // collateral would be seized while the repayment never arrives.
        vm.mockCall(address(asset), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));

        vm.prank(liquidator);
        vm.expectRevert(bytes("TRANSFER"));
        pool.liquidate(borrower, 15_000e18);
        assertGt(pool.collateralOf(borrower), 0, "collateral left the borrower");
    }

    // ------------------------------------------------------------- timelock integration

    function test_timelock_gates_owner_calls() public {
        Timelock timelock = new Timelock(address(this), 1 days);
        pool.transferOwnership(address(timelock));

        bytes memory accept = abi.encodeCall(LendingPool.acceptOwnership, ());
        bytes32 id = timelock.queue(address(pool), 0, accept);

        vm.expectRevert(bytes("TOO_EARLY"));
        timelock.execute(id, address(pool), 0, accept);

        vm.warp(block.timestamp + 1 days);
        timelock.execute(id, address(pool), 0, accept);
        assertEq(pool.owner(), address(timelock));

        bytes memory setParams = abi.encodeCall(LendingPool.setRiskParams, (0.7e18, 0.85e18, 0.04e18));
        bytes32 id2 = timelock.queue(address(pool), 0, setParams);
        vm.warp(block.timestamp + 1 days);
        timelock.execute(id2, address(pool), 0, setParams);
        assertEq(pool.ltv(), 0.7e18);
    }
}
