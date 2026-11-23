// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice One-shot demo against the Sepolia deployment: mint test tokens, lend, post collateral,
///         borrow. Run `PokePrice.s.sol` first, otherwise `borrow` reverts on the oracle.
///
///         POOL_ADDRESS / ASSET_ADDRESS / COLLATERAL_ADDRESS from deployments.md
contract SeedDemo is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        // Defaults point at the 2026-11-23 Sepolia deployment (deployments.md); override with env
        // vars if you redeploy.
        LendingPool pool = LendingPool(vm.envOr("POOL_ADDRESS", address(0x678377b69DbC206F30D40Fba48B21006c750AA35)));
        MockERC20 asset = MockERC20(vm.envOr("ASSET_ADDRESS", address(0x535C69CC15541F87a0B5e0496F863A6F7B3869b8)));
        MockERC20 collateral =
            MockERC20(vm.envOr("COLLATERAL_ADDRESS", address(0x745A7e61745A62398F9DeA155feD14483938f1eC)));

        uint256 lendAmount = 10_000e18;
        uint256 collateralAmount = 5e18;
        uint256 borrowAmount = 5_000e18;

        vm.startBroadcast(pk);

        asset.mint(me, lendAmount);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(lendAmount, me);

        collateral.mint(me, collateralAmount);
        collateral.approve(address(pool), type(uint256).max);
        pool.depositCollateral(collateralAmount);

        pool.borrow(borrowAmount, me);

        vm.stopBroadcast();

        console2.log("shares", pool.balanceOf(me));
        console2.log("totalAssets", pool.totalAssets());
        console2.log("debt", pool.debtOf(me));
        console2.log("collateral", pool.collateralOf(me));
    }
}
