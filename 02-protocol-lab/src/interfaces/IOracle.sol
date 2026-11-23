// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Price of one whole unit of collateral, scaled to 1e18, denominated in the loan asset.
interface IOracle {
    function price() external view returns (uint256);
}
