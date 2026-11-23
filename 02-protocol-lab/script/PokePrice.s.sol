// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "../test/mocks/MockFeeds.sol";

/// @notice Pushes one fresh price into the deployed demo oracle.
///
///         The TWAP needs two pushes at least `window` apart. Deploy pushes the first one; wait a
///         minute, run this, and `price()` starts answering.
///
///         ORACLE_ADDRESS=<oracle from DeployTestnet> PRICE=<optional, default 2000e18>
contract PokePrice is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        // Default is the 2026-11-23 Sepolia deployment; override with ORACLE_ADDRESS if needed.
        TwapOracle oracle = TwapOracle(vm.envOr("ORACLE_ADDRESS", address(0xE567dB9926b81E486edF81767AbD19F79CB58d2A)));
        uint256 newPrice = vm.envOr("PRICE", uint256(2000e18));
        MockFeed feed = MockFeed(address(oracle.feed()));

        vm.startBroadcast(pk);
        feed.set(int256(newPrice / 1e10), block.timestamp);
        oracle.pushPrice(newPrice);
        vm.stopBroadcast();

        console2.log("pushed price", newPrice);
    }
}
