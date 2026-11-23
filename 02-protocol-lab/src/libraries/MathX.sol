// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal fixed-point helpers. Callers are responsible for keeping products inside uint256:
///         with 18-decimal amounts the checked multiply reverts well before any realistic balance
///         reaches the overflow bound.
library MathX {
    uint256 internal constant WAD = 1e18;

    function mulDivDown(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }

    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + d - 1) / d;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD) / b;
    }

    function wadDivUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD + b - 1) / b;
    }
}
