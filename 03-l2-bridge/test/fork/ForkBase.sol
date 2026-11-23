// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

/// @notice Shared setup for the fork tests. One fork per chain, both pinned through env vars so a
///         run can be reproduced exactly:
///
///         OP_L1_RPC, OP_L2_RPC          endpoints (defaults target OP Sepolia)
///         OP_L1_BLOCK, OP_L2_BLOCK      block numbers to pin (0 = latest; see FORKS.md)
///         OP_L1_BRIDGE, OP_PORTAL, OP_SYSTEM_CONFIG, OP_DGF
///                                        L1 system addresses (defaults are OP Sepolia's)
///         OP_PROXY_ADMIN_OWNER          the governance address that owns the L1 ProxyAdmin
///         OP_L1_TOKEN, OP_L2_TOKEN      a bridged pair to check decimals on
///
///         Defaults are deliberately not hardcoded into each test: a second chain is one export away.
abstract contract ForkBase is Test {
    // L2 predeploys: fixed by the OP Stack, identical on every chain.
    address internal constant L2_CDM = 0x4200000000000000000000000000000000000007;
    address internal constant L2_BRIDGE = 0x4200000000000000000000000000000000000010;
    address internal constant L2_PROXY_ADMIN = 0x4200000000000000000000000000000000000018;
    address internal constant L2_WETH = 0x4200000000000000000000000000000000000006;

    // OP Sepolia, from the superchain registry (sepolia/op.toml).
    address internal constant OP_SEPOLIA_L1_BRIDGE = 0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1;
    address internal constant OP_SEPOLIA_PORTAL = 0x16Fc5058F25648194471939df75CF27A2fdC48BC;
    address internal constant OP_SEPOLIA_SYSTEM_CONFIG = 0x034edD2A225f7f429A63E0f1D2084B9E0A93b538;
    address internal constant OP_SEPOLIA_DGF = 0x05F9613aDB30026FFd634f38e5C4dFd30a197Fa1;
    address internal constant OP_SEPOLIA_PROXY_ADMIN_OWNER = 0x1Eb2fFc903729a0F03966B917003800b145F56E2;
    address internal constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    uint256 internal l1ForkId;
    uint256 internal l2ForkId;
    uint256 internal l1ForkBlock;
    uint256 internal l2ForkBlock;

    address internal l1Bridge;
    address internal l1Cdm;
    address internal portal;
    address internal systemConfig;
    address internal disputeGameFactory;
    address internal superchainConfig;
    address internal proxyAdminOwner;

    function setUp() public virtual {
        string memory l1Rpc = vm.envOr("OP_L1_RPC", string("https://ethereum-sepolia-rpc.publicnode.com"));
        string memory l2Rpc = vm.envOr("OP_L2_RPC", string("https://sepolia.optimism.io"));

        uint256 pinL1 = vm.envOr("OP_L1_BLOCK", uint256(0));
        uint256 pinL2 = vm.envOr("OP_L2_BLOCK", uint256(0));

        l1ForkId = pinL1 == 0 ? vm.createFork(l1Rpc) : vm.createFork(l1Rpc, pinL1);
        l2ForkId = pinL2 == 0 ? vm.createFork(l2Rpc) : vm.createFork(l2Rpc, pinL2);

        l1Bridge = vm.envOr("OP_L1_BRIDGE", OP_SEPOLIA_L1_BRIDGE);
        portal = vm.envOr("OP_PORTAL", OP_SEPOLIA_PORTAL);
        systemConfig = vm.envOr("OP_SYSTEM_CONFIG", OP_SEPOLIA_SYSTEM_CONFIG);
        disputeGameFactory = vm.envOr("OP_DGF", OP_SEPOLIA_DGF);
        proxyAdminOwner = vm.envOr("OP_PROXY_ADMIN_OWNER", OP_SEPOLIA_PROXY_ADMIN_OWNER);

        vm.selectFork(l1ForkId);
        l1ForkBlock = vm.getBlockNumber();
        // Derived, never hardcoded: the bridge is the authority on which messenger it trusts.
        l1Cdm = _bridgeMessenger(l1Bridge);
        superchainConfig = _portalSuperchainConfig(portal);

        vm.selectFork(l2ForkId);
        l2ForkBlock = vm.getBlockNumber();
    }

    function _onL1() internal {
        vm.selectFork(l1ForkId);
    }

    function _onL2() internal {
        vm.selectFork(l2ForkId);
    }

    /// @dev Solidity cannot call a getter that does not exist without reverting the whole test, so
    ///      the optional getters are read through low-level calls.
    function _tryGetAddress(address target, bytes memory data) internal view returns (bool ok, address value) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        if (ok && ret.length == 32) {
            value = address(uint160(uint256(bytes32(ret))));
        }
    }

    function _bridgeMessenger(address bridge) internal view returns (address) {
        return _readAddress(bridge, abi.encodeWithSignature("messenger()"));
    }

    function _portalSuperchainConfig(address _portal) internal view returns (address) {
        return _readAddress(_portal, abi.encodeWithSignature("superchainConfig()"));
    }

    function _readAddress(address target, bytes memory data) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        require(ok && ret.length == 32, "read failed");
        return address(uint160(uint256(bytes32(ret))));
    }

    function _readUint(address target, bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        require(ok && ret.length == 32, "read failed");
        return uint256(bytes32(ret));
    }

    function _readString(address target, bytes memory data) internal view returns (string memory) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        require(ok, "read failed");
        return abi.decode(ret, (string));
    }

    /// @dev Finds a 4-byte selector in runtime bytecode. Used to identify a proxy pattern that keeps
    ///      no EIP-1967 slots, where the only mark left on-chain is the call it makes.
    function _contains(bytes memory haystack, bytes4 needle) internal pure returns (bool) {
        if (haystack.length < 4) return false;
        for (uint256 i = 0; i <= haystack.length - 4; i++) {
            if (
                haystack[i] == needle[0] && haystack[i + 1] == needle[1] && haystack[i + 2] == needle[2]
                    && haystack[i + 3] == needle[3]
            ) {
                return true;
            }
        }
        return false;
    }

    function _adminSlot() internal pure returns (bytes32) {
        return bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    }

    function _implSlot() internal pure returns (bytes32) {
        return bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    }

    function _adminOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _adminSlot()))));
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _implSlot()))));
    }
}
