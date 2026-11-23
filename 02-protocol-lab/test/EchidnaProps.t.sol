// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {EchidnaProps} from "./echidna/EchidnaProps.sol";

/// @notice Keeps the Echidna harness honest: it must deploy and its properties must hold on the
///         empty state, independently of the fuzzer.
contract EchidnaPropsTest is Test {
    EchidnaProps props;

    function setUp() public {
        uint256 gasBefore = gasleft();
        props = new EchidnaProps();
        emit log_named_uint("deploy gas", gasBefore - gasleft());
    }

    function test_harness_deploys() public view {
        assertGt(address(props).code.length, 0);
    }

    function test_empty_state_properties_hold() public view {
        assertTrue(props.echidna_total_assets_match());
        assertTrue(props.echidna_collateral_backed());
        assertTrue(props.echidna_debt_within_total());
    }
}
