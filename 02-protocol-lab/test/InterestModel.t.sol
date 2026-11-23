// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {InterestModel} from "../src/InterestModel.sol";

contract InterestModelTest is Test {
    InterestModel model;

    function setUp() public {
        model = new InterestModel(0.01e18, 0.05e18, 0.5e18, 0.8e18);
    }

    function test_zero_utilization_pays_base() public view {
        assertEq(model.apr(0), 0.01e18);
    }

    function test_below_kink_is_linear() public view {
        // 40% utilization: base 1% + 40% * 5% / 80% = 3.5%
        assertEq(model.apr(0.4e18), 0.035e18);
    }

    function test_at_kink_adds_full_slope_one() public view {
        assertEq(model.apr(0.8e18), 0.06e18);
    }

    function test_above_kink_adds_slope_two() public view {
        // 100%: 1% + 5% + 50%
        assertEq(model.apr(1e18), 0.56e18);
    }

    function test_utilization_is_capped_at_one() public view {
        assertEq(model.apr(2e18), model.apr(1e18));
    }

    function test_rate_per_second_is_apr_over_year() public view {
        assertEq(model.ratePerSecond(0.8e18), uint256(0.06e18) / 365 days);
    }

    function test_rejects_bad_kink() public {
        vm.expectRevert(bytes("KINK"));
        new InterestModel(0, 0.05e18, 0.5e18, 0);

        vm.expectRevert(bytes("KINK"));
        new InterestModel(0, 0.05e18, 0.5e18, 1e18);
    }
}
