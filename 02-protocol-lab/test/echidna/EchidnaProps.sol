// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {LendingPool} from "../../src/LendingPool.sol";
import {InterestModel} from "../../src/InterestModel.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedOracle} from "./FixedOracle.sol";

/// @notice Echidna properties. The campaign calls the public entry points with fuzzed arguments;
///         any revert is treated as a skipped input, so the functions stay permissive.
contract EchidnaProps {
    MockERC20 public asset;
    MockERC20 public collateral;
    FixedOracle public oracle;
    InterestModel public model;
    LendingPool public pool;

    /// @dev Echidna funds the contract at deployment; the constructor must accept value and the
    ///      runtime must be able to receive refunds.
    receive() external payable {}

    constructor() payable {
        asset = new MockERC20("USD", "USD", 18);
        collateral = new MockERC20("WETH", "WETH", 18);
        oracle = new FixedOracle(2000e18);
        model = new InterestModel(0, 0.05e18, 0.5e18, 0.8e18);
        pool = new LendingPool(asset, collateral, oracle, model, address(this));

        asset.mint(address(this), 1e30);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e18, address(this));

        collateral.mint(address(this), 1_000e18);
        collateral.approve(address(pool), type(uint256).max);
        pool.depositCollateral(100e18);
    }

    function deposit(uint256 amount) external {
        amount = (amount % 10_000e18) + 1;
        asset.mint(address(this), amount);
        pool.deposit(amount, address(this));
    }

    function withdraw(uint256 amount) external {
        uint256 max = pool.maxWithdraw(address(this));
        if (max == 0) return;
        amount = (amount % max) + 1;
        pool.withdraw(amount, address(this), address(this));
    }

    function borrow(uint256 amount) external {
        amount = (amount % 100_000e18) + 1;
        pool.borrow(amount, address(this));
    }

    function repay(uint256 amount) external {
        uint256 debt = pool.debtOf(address(this));
        if (debt == 0) return;
        amount = (amount % debt) + 1;
        asset.mint(address(this), amount);
        pool.repay(amount);
    }

    function addCollateral(uint256 amount) external {
        amount = (amount % 100e18) + 1;
        collateral.mint(address(this), amount);
        pool.depositCollateral(amount);
    }

    function echidna_total_assets_match() public view returns (bool) {
        return pool.totalAssets() == asset.balanceOf(address(pool)) + pool.totalDebt();
    }

    function echidna_collateral_backed() public view returns (bool) {
        return collateral.balanceOf(address(pool)) >= pool.collateralOf(address(this));
    }

    function echidna_debt_within_total() public view returns (bool) {
        // Debt is tracked in shares, so a position's floored debt can never exceed the pool total.
        // Before the fix this failed by 1-2 wei (see audit/AUDIT.md F-02).
        return pool.debtOf(address(this)) <= pool.totalDebt();
    }
}
