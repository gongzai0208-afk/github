// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/console2.sol";
import {ForkBase} from "./ForkBase.sol";
import {
    IStandardBridge,
    ICrossDomainMessenger,
    IOptimismPortal,
    ISuperchainConfig,
    IDisputeGameFactory,
    IProxyAdmin,
    IERC20Metadata
} from "../../src/interfaces/IOpStack.sol";

/// @notice Reads the live deployment and asserts the wiring an operator is supposed to have. Every
///         assertion is structural (addresses must agree with each other), so the same suite runs
///         against any OP Stack chain; only the local system addresses change.
contract WiringTest is ForkBase {
    address internal constant DEFAULT_L2_SENDER = 0x000000000000000000000000000000000000dEaD;

    /// @dev Selector of `getAddress(string)`: the only upgrade path a legacy ResolvedDelegateProxy
    ///      exposes, and thus the mark that identifies one.
    bytes4 internal constant GET_ADDRESS_SELECTOR = 0xbf40fac1;

    function test_A1_messengers_are_paired() public {
        _onL1();
        assertEq(IStandardBridge(l1Bridge).messenger(), l1Cdm, "L1 bridge: messenger");
        assertEq(ICrossDomainMessenger(l1Cdm).OTHER_MESSENGER(), L2_CDM, "L1 messenger: otherMessenger");
        assertEq(IStandardBridge(l1Bridge).otherBridge(), L2_BRIDGE, "L1 bridge: otherBridge");

        _onL2();
        assertEq(IStandardBridge(L2_BRIDGE).messenger(), L2_CDM, "L2 bridge: messenger");
        assertEq(ICrossDomainMessenger(L2_CDM).OTHER_MESSENGER(), l1Cdm, "L2 messenger: otherMessenger");
        assertEq(IStandardBridge(L2_BRIDGE).otherBridge(), l1Bridge, "L2 bridge: otherBridge");
    }

    /// @dev A1 asks whether the messenger points at the right counterpart. The bridge is the
    ///      authority: the messenger the bridge trusts is the one it will accept finalisations from.
    function test_A1_l1_bridge_uses_the_messenger_that_points_back() public {
        _onL1();
        assertEq(ICrossDomainMessenger(l1Cdm).OTHER_MESSENGER(), L2_CDM);
        assertEq(IStandardBridge(l1Bridge).messenger(), l1Cdm);
        assertTrue(l1Cdm != address(0), "zero messenger");
    }

    /// @dev The version lives in the top 16 bits of the nonce. Anything but 1 means a message
    ///      encoding this deployment does not produce or cannot relay.
    function test_A2_nonce_carries_the_message_version() public {
        _onL1();
        assertEq(ICrossDomainMessenger(l1Cdm).messageNonce() >> 240, 1, "L1 nonce version");
        _onL2();
        assertEq(ICrossDomainMessenger(L2_CDM).messageNonce() >> 240, 1, "L2 nonce version");
    }

    /// @dev Outside a relay the sender getter must revert; a silent zero would let a target treat
    ///      "no message" as "message from address(0)".
    function test_A4_xDomainMessageSender_reverts_when_idle() public {
        _onL1();
        vm.expectRevert();
        ICrossDomainMessenger(l1Cdm).xDomainMessageSender();
        assertEq(IOptimismPortal(portal).l2Sender(), DEFAULT_L2_SENDER, "portal l2Sender not idle");

        _onL2();
        vm.expectRevert();
        ICrossDomainMessenger(L2_CDM).xDomainMessageSender();
    }

    function test_B1_withdrawal_delays_are_configured() public {
        _onL1();
        uint256 maturity = IOptimismPortal(portal).proofMaturityDelaySeconds();
        uint256 gameFinality = IOptimismPortal(portal).disputeGameFinalityDelaySeconds();
        uint256 expectedMaturity = vm.envOr("OP_PROOF_MATURITY", uint256(7 days));
        uint256 expectedFinality = vm.envOr("OP_GAME_FINALITY", uint256(3.5 days));

        assertEq(maturity, expectedMaturity, "proof maturity delay");
        assertEq(gameFinality, expectedFinality, "dispute game finality delay");
    }

    /// @dev D1: the L2 token is the mirror of the L1 token and the decimals agree. The bridge moves
    ///      raw units, so a silent decimals change is a 10^n error in every integration.
    function test_D1_bridged_token_decimals_match() public {
        address l1Token = vm.envOr("OP_L1_TOKEN", SEPOLIA_WETH);
        address l2Token = vm.envOr("OP_L2_TOKEN", L2_WETH);

        _onL1();
        uint8 l1Decimals = IERC20Metadata(l1Token).decimals();
        string memory l1Symbol = IERC20Metadata(l1Token).symbol();
        assertGt(l1Token.code.length, 0, "L1 token has no code");

        _onL2();
        assertGt(l2Token.code.length, 0, "L2 token has no code");
        assertEq(IERC20Metadata(l2Token).decimals(), l1Decimals, "decimals differ across the bridge");
        assertEq(IERC20Metadata(l2Token).symbol(), l1Symbol, "symbol differs across the bridge");

        // The native L2 WETH predeploy is not an OptimismMintableERC20 and has no pair getters, so
        // the pair check only runs when the token actually exposes them.
        (bool ok, address remote) = _tryGetAddress(l2Token, abi.encodeWithSignature("remoteToken()"));
        if (ok) assertEq(remote, l1Token, "remoteToken mismatch");
    }

    /// @dev E1: the proxy admin is a contract, its owner is the governance address from the
    ///      registry, and that owner is itself a contract on the chain where it lives.
    function test_E1_l1_governance_is_a_contract() public {
        _onL1();
        address admin = _adminOf(l1Bridge);
        assertTrue(admin != address(0), "L1 bridge has no EIP-1967 admin");
        assertGt(admin.code.length, 0, "proxy admin is not a contract");

        address owner = IProxyAdmin(admin).owner();
        assertEq(owner, proxyAdminOwner, "proxy admin owner differs from the registry");
        assertGt(owner.code.length, 0, "proxy admin owner is an EOA on L1");

        assertTrue(_implOf(l1Bridge) != address(0), "L1 bridge has no implementation");
        assertTrue(_implOf(portal) != address(0), "portal has no implementation");
    }

    /// @dev E3: the L1 messenger is not a normal proxy. It keeps no EIP-1967 implementation slot;
    ///      it resolves its target through the legacy AddressManager on every call, which makes
    ///      `AddressManager.setAddress` the real upgrade entry point (owner-only, owner = ProxyAdmin).
    ///      The selector in the bytecode is the evidence, and `version()` proves resolution works.
    function test_E3_l1_messenger_is_a_legacy_resolved_proxy() public {
        _onL1();
        assertEq(_implOf(l1Cdm), address(0), "unexpected EIP-1967 implementation slot");
        assertGt(l1Cdm.code.length, 0, "messenger has no code");
        assertTrue(_contains(l1Cdm.code, GET_ADDRESS_SELECTOR), "no getAddress(string) in bytecode");

        string memory v = _readString(l1Cdm, abi.encodeWithSignature("version()"));
        assertGt(bytes(v).length, 0, "messenger does not resolve");
        console2.log("L1 messenger version", v);
    }

    /// @dev The L2 predeploys are upgraded through the L2 ProxyAdmin. That admin has an owner on
    ///      every chain; whether it is the same address as the L1 owner is a governance choice, so
    ///      this test asserts presence and records the values rather than assuming equality.
    function test_E1_l2_predeploys_are_governed() public {
        _onL2();
        assertEq(_adminOf(L2_BRIDGE), L2_PROXY_ADMIN, "L2 bridge admin is not the ProxyAdmin predeploy");
        address l2Owner = IProxyAdmin(L2_PROXY_ADMIN).owner();
        assertTrue(l2Owner != address(0), "L2 ProxyAdmin has no owner");
        assertTrue(_implOf(L2_BRIDGE) != address(0), "L2 bridge has no implementation");
        assertTrue(_implOf(L2_CDM) != address(0), "L2 messenger has no implementation");

        console2.log("L1 ProxyAdmin owner", proxyAdminOwner);
        console2.log("L2 ProxyAdmin owner", l2Owner);
        console2.log("L2 owner code (L2)", l2Owner.code.length);
    }

    function test_F2_nothing_is_paused() public {
        _onL1();
        assertFalse(IStandardBridge(l1Bridge).paused(), "L1 bridge paused");
        assertFalse(ICrossDomainMessenger(l1Cdm).paused(), "L1 messenger paused");
        assertFalse(IOptimismPortal(portal).paused(), "portal paused");
        assertFalse(ISuperchainConfig(superchainConfig).paused(), "superchain config paused");

        _onL2();
        assertFalse(IStandardBridge(L2_BRIDGE).paused(), "L2 bridge paused");
        assertFalse(ICrossDomainMessenger(L2_CDM).paused(), "L2 messenger paused");
    }

    function test_F3_portal_wiring_matches_the_registry() public {
        _onL1();
        assertEq(IOptimismPortal(portal).systemConfig(), systemConfig, "portal.systemConfig");
        assertEq(IOptimismPortal(portal).disputeGameFactory(), disputeGameFactory, "portal.disputeGameFactory");
        assertTrue(IOptimismPortal(portal).guardian() != address(0), "no guardian");
        assertEq(IOptimismPortal(portal).superchainConfig(), superchainConfig, "superchainConfig");

        (bool ok, address fromSystemConfig) =
            _tryGetAddress(systemConfig, abi.encodeWithSignature("l1CrossDomainMessenger()"));
        if (ok) assertEq(fromSystemConfig, l1Cdm, "systemConfig.l1CrossDomainMessenger");
    }

    function test_F4_respected_game_type_has_an_implementation() public {
        _onL1();
        uint32 gameType = IOptimismPortal(portal).respectedGameType();
        assertGt(IDisputeGameFactory(disputeGameFactory).gameCount(), 0, "no dispute games");
        assertTrue(
            IDisputeGameFactory(disputeGameFactory).gameImpls(gameType) != address(0),
            "respected game type has no implementation"
        );
    }

    /// @dev Not an assertion: a snapshot printed into the run log, which is what the report quotes.
    function test_print_snapshot() public view {
        console2.log("L1 block", l1ForkBlock);
        console2.log("L2 block", l2ForkBlock);
        console2.log("L1 bridge", l1Bridge);
        console2.log("L1 messenger", l1Cdm);
        console2.log("portal", portal);
        console2.log("systemConfig", systemConfig);
        console2.log("disputeGameFactory", disputeGameFactory);
        console2.log("superchainConfig", superchainConfig);
    }
}
