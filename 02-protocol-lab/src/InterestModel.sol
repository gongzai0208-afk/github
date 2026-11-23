// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {MathX} from "./libraries/MathX.sol";

/// @notice Linear rate model with a kink. Rates are per year in WAD; the pool converts to per second.
contract InterestModel {
    using MathX for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public immutable baseRate;
    uint256 public immutable slope1;
    uint256 public immutable slope2;
    uint256 public immutable kink;

    constructor(uint256 baseRate_, uint256 slope1_, uint256 slope2_, uint256 kink_) {
        require(kink_ > 0 && kink_ < WAD, "KINK");
        baseRate = baseRate_;
        slope1 = slope1_;
        slope2 = slope2_;
        kink = kink_;
    }

    /// @notice Borrow APR at a given utilization, WAD.
    function apr(uint256 utilization) public view returns (uint256) {
        uint256 u = utilization.min(WAD);
        if (u <= kink) {
            return baseRate + (u.wadMul(slope1) * WAD) / kink;
        }
        return baseRate + slope1 + ((u - kink) * slope2) / (WAD - kink);
    }

    /// @notice Per-second rate, WAD. Truncates; the pool accrues the remainder next block.
    function ratePerSecond(uint256 utilization) external view returns (uint256) {
        return apr(utilization) / SECONDS_PER_YEAR;
    }
}
