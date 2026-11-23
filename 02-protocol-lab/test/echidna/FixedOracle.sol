// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice Fixed price for the Echidna campaign. The real oracle has its own unit tests; the
///         campaign is about accounting, not about price discovery.
contract FixedOracle is IOracle {
    uint256 public immutable priceValue;

    constructor(uint256 price_) {
        priceValue = price_;
    }

    function price() external view returns (uint256) {
        return priceValue;
    }
}
