// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IOracle} from "./interfaces/IOracle.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @notice TWAP over keeper-pushed prices, cross-checked against a Chainlink-style feed.
///
///         Why not read the feed directly: a single spot answer is movable inside one block and has
///         no history. Why not trust the TWAP alone: it lags, so a fast move is invisible until the
///         window passes. The oracle therefore returns the TWAP but refuses to answer when the feed
///         disagrees beyond `maxDeviation`, when the feed is stale, when the L2 sequencer is down,
///         or when the sequencer came back less than `gracePeriod` ago.
contract TwapOracle is IOracle {
    uint256 public constant WAD = 1e18;
    uint256 public constant CAP = 32;

    struct Checkpoint {
        uint64 ts;
        uint256 cumulative;
        uint256 price;
    }

    Checkpoint[CAP] private _checkpoints;
    uint256 public count;
    uint256 public nextIndex;

    uint256 public lastTs;
    uint256 public lastPrice;
    uint256 public cumulative;

    AggregatorV3Interface public immutable feed;
    AggregatorV3Interface public immutable sequencer;
    uint256 public immutable feedScale;

    address public owner;
    address public feeder;

    uint256 public window;
    uint256 public heartbeat;
    uint256 public maxAge;
    uint256 public maxDeviation;
    uint256 public gracePeriod;

    event PricePushed(uint256 price, uint256 timestamp, uint256 cumulative);
    event FeederChanged(address indexed feeder);
    event ParamsChanged(uint256 window, uint256 heartbeat, uint256 maxAge, uint256 maxDeviation, uint256 gracePeriod);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(
        address owner_,
        address feeder_,
        AggregatorV3Interface feed_,
        AggregatorV3Interface sequencer_,
        uint256 window_,
        uint256 heartbeat_,
        uint256 maxAge_,
        uint256 maxDeviation_,
        uint256 gracePeriod_
    ) {
        require(owner_ != address(0), "OWNER");
        require(feeder_ != address(0), "FEEDER");
        require(address(feed_) != address(0), "FEED");
        require(window_ > 0 && heartbeat_ >= window_, "WINDOW");
        uint8 decimals = feed_.decimals();
        require(decimals <= 18, "DECIMALS");
        owner = owner_;
        feeder = feeder_;
        feed = feed_;
        sequencer = sequencer_;
        feedScale = 10 ** (18 - decimals);
        window = window_;
        heartbeat = heartbeat_;
        maxAge = maxAge_;
        maxDeviation = maxDeviation_;
        gracePeriod = gracePeriod_;
    }

    // ---------------------------------------------------------------- push

    function pushPrice(uint256 newPrice) external {
        require(msg.sender == feeder, "NOT_FEEDER");
        require(newPrice > 0, "PRICE");
        uint256 dt = block.timestamp - lastTs;
        if (dt > 0 && lastPrice > 0) {
            cumulative += lastPrice * dt;
        }
        lastTs = block.timestamp;
        lastPrice = newPrice;
        _checkpoints[nextIndex] = Checkpoint(uint64(block.timestamp), cumulative, newPrice);
        nextIndex = (nextIndex + 1) % CAP;
        if (count < CAP) count++;
        emit PricePushed(newPrice, block.timestamp, cumulative);
    }

    // ---------------------------------------------------------------- read

    function cumulativeAt(uint256 target) public view returns (uint256) {
        require(count > 0, "NO_HISTORY");
        require(target <= block.timestamp, "FUTURE");
        if (target >= lastTs) {
            return cumulative + lastPrice * (target - lastTs);
        }
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = (nextIndex + CAP - 1 - i) % CAP;
            Checkpoint memory c = _checkpoints[idx];
            if (c.ts <= target) {
                return c.cumulative + c.price * (target - c.ts);
            }
        }
        revert("NO_HISTORY");
    }

    function twap() public view returns (uint256) {
        require(count > 0, "NO_HISTORY");
        require(block.timestamp >= window, "WINDOW");
        require(block.timestamp - lastTs <= heartbeat, "STALE");
        uint256 target = block.timestamp - window;
        uint256 start = cumulativeAt(target);
        uint256 end = cumulative + lastPrice * (block.timestamp - lastTs);
        return (end - start) / window;
    }

    function price() external view returns (uint256) {
        uint256 twapPrice = twap();
        uint256 feedPrice = _feedPrice();
        _requireSequencerUp();

        uint256 diff = twapPrice > feedPrice ? twapPrice - feedPrice : feedPrice - twapPrice;
        require((diff * WAD) / twapPrice <= maxDeviation, "DEVIATION");
        return twapPrice;
    }

    function _feedPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        require(answer > 0, "FEED_ANSWER");
        require(updatedAt + maxAge >= block.timestamp, "FEED_STALE");
        require(answeredInRound >= roundId, "FEED_ROUND");
        return uint256(answer) * feedScale;
    }

    function _requireSequencerUp() internal view {
        if (address(sequencer) == address(0)) return;
        (, int256 status, uint256 startedAt, , ) = sequencer.latestRoundData();
        require(status == 0, "SEQUENCER_DOWN");
        require(startedAt + gracePeriod <= block.timestamp, "SEQUENCER_GRACE");
    }

    // ---------------------------------------------------------------- admin

    function setFeeder(address feeder_) external onlyOwner {
        require(feeder_ != address(0), "FEEDER");
        feeder = feeder_;
        emit FeederChanged(feeder_);
    }

    function setParams(
        uint256 window_,
        uint256 heartbeat_,
        uint256 maxAge_,
        uint256 maxDeviation_,
        uint256 gracePeriod_
    ) external onlyOwner {
        require(window_ > 0 && heartbeat_ >= window_, "WINDOW");
        require(maxDeviation_ <= WAD, "DEVIATION");
        window = window_;
        heartbeat = heartbeat_;
        maxAge = maxAge_;
        maxDeviation = maxDeviation_;
        gracePeriod = gracePeriod_;
        emit ParamsChanged(window_, heartbeat_, maxAge_, maxDeviation_, gracePeriod_);
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
