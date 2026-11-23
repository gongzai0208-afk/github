// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {InterestModel} from "../src/InterestModel.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {Timelock} from "../src/Timelock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockFeed} from "../test/mocks/MockFeeds.sol";

/// @notice Sepolia deployment of the testbed: mock tokens, a mock feed, the real oracle, and a
///         timelock that owns the pool. Nothing here is production configuration.
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "WRONG_CHAIN");
        console2.log("chainid", block.chainid);

        vm.startBroadcast(pk);

        MockERC20 asset = new MockERC20("Test USD", "tUSD", 18);
        MockERC20 collateral = new MockERC20("Test WETH", "tWETH", 18);

        MockFeed feed = new MockFeed();
        feed.set(2000e8, block.timestamp);

        TwapOracle oracle = new TwapOracle(
            deployer,
            deployer,
            AggregatorV3Interface(address(feed)),
            AggregatorV3Interface(address(0)),
            // Demo window: 60s instead of 30 minutes, so the oracle becomes live after the
            // second price push (see PokePrice.s.sol) rather than half an hour later.
            60,
            3600,
            3600,
            0.05e18,
            1800
        );
        oracle.pushPrice(2000e18);

        InterestModel model = new InterestModel(0, 0.05e18, 0.5e18, 0.8e18);
        Timelock timelock = new Timelock(deployer, 1 days);
        LendingPool pool = new LendingPool(asset, collateral, oracle, model, address(timelock));

        oracle.transferOwnership(address(timelock));

        vm.stopBroadcast();

        console2.log("asset", address(asset));
        console2.log("collateral", address(collateral));
        console2.log("feed", address(feed));
        console2.log("oracle", address(oracle));
        console2.log("model", address(model));
        console2.log("timelock", address(timelock));
        console2.log("pool", address(pool));
    }
}
