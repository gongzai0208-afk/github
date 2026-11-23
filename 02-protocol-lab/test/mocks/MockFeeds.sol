// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockFeed is AggregatorV3Interface {
    uint8 public constant decimals = 8;

    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId += 1;
        answeredInRound = roundId;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract MockSequencer is AggregatorV3Interface {
    uint8 public constant decimals = 0;

    int256 public status;
    uint256 public startedAt;

    function set(int256 status_, uint256 startedAt_) external {
        status = status_;
        startedAt = startedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, status, startedAt, startedAt, 1);
    }
}
