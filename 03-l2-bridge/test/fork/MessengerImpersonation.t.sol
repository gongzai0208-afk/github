// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/console2.sol";
import {ForkBase} from "./ForkBase.sol";
import {AddressAliasHelper} from "../../src/libraries/AddressAliasHelper.sol";
import {IStandardBridge, ICrossDomainMessenger} from "../../src/interfaces/IOpStack.sol";
import {MintableToken} from "../mocks/MintableToken.sol";

/// @notice The L2 messenger authenticates a relay with one predicate:
///
///             undoL1ToL2Alias(msg.sender) == otherMessenger
///
///         That is a statement about an address, not about who controls it. Everything an L2
///         contract trusts about L1 -- including `xDomainMessageSender()`, which the standard bridge
///         uses to accept finalisations -- rests on nobody being able to transact from
///         `applyL1ToL2Alias(L1CrossDomainMessenger)`.
///
///         These tests prove both halves of that statement:
///           1. if that address were controllable, a hand-built `relayMessage` would be accepted as
///              a genuine L1 message and its target would trust the forged sender;
///           2. on the live chain the address holds no code, so the precondition is absent.
contract MessengerImpersonationTest is ForkBase {
    address internal constant ATTACKER = 0x00000000000000000000000000000000000A11cE;

    /// @dev C1: the aliased L1 messenger must be a dead address on L2. This is what turns "anyone
    ///      may call relayMessage" into "only the L1 messenger can".
    function test_C1_aliased_l1_messenger_has_no_code_on_l2() public {
        _onL2();
        address aliased = AddressAliasHelper.applyL1ToL2Alias(l1Cdm);
        console2.log("L1 messenger", l1Cdm);
        console2.log("alias(L1 messenger)", aliased);
        console2.log("stranded wei at alias", aliased.balance);

        assertEq(AddressAliasHelper.undoL1ToL2Alias(aliased), l1Cdm, "alias roundtrip");
        assertEq(aliased.code.length, 0, "code exists at the aliased messenger address");
        // The L1 bridge's own address must also be unused on L2: it is the value that
        // `xDomainMessageSender()` has to return for a finalisation to be accepted.
        assertEq(l1Bridge.code.length, 0, "code exists at the L1 bridge address on L2");
    }

    function test_A4_unauthorised_caller_cannot_relay() public {
        _onL2();
        vm.prank(ATTACKER);
        vm.expectRevert();
        ICrossDomainMessenger(L2_CDM).relayMessage(1, l1Bridge, L2_BRIDGE, 0, 200_000, "");
    }

    /// @dev A3/A4: neither bridge accepts a finalisation from a direct caller. The messenger check
    ///      and the `xDomainMessageSender` check are both enforced.
    function test_A3_bridges_reject_direct_callers() public {
        _onL2();
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("StandardBridge: function can only be called from the other bridge"));
        IStandardBridge(L2_BRIDGE).finalizeBridgeETH(ATTACKER, ATTACKER, 0, "");

        _onL1();
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("StandardBridge: function can only be called from the other bridge"));
        IStandardBridge(l1Bridge).finalizeBridgeETH(ATTACKER, ATTACKER, 0, "");
    }

    /// @dev The PoC, part 1: with the sender pranked to the aliased messenger address, a hand-built
    ///      `relayMessage` is accepted as a genuine L1->L2 message and the bridge finalises it. No
    ///      proof, no portal, no sequencer. Zero value, because `finalizeBridgeETH` requires
    ///      `msg.value == _amount` and is a pass-through: the value-carrying path is part 2.
    function test_POC_alias_bypass_is_accepted_as_cross_domain() public {
        _onL2();
        address aliased = AddressAliasHelper.applyL1ToL2Alias(l1Cdm);

        bytes memory finalize =
            abi.encodeCall(IStandardBridge.finalizeBridgeETH, (ATTACKER, ATTACKER, 0, ""));
        uint256 nonce = ICrossDomainMessenger(L2_CDM).messageNonce();
        bytes memory relay = abi.encodeCall(
            ICrossDomainMessenger.relayMessage, (nonce, l1Bridge, L2_BRIDGE, 0, 200_000, finalize)
        );

        vm.prank(aliased);
        (bool ok,) = L2_CDM.call(relay);
        assertTrue(ok, "relay rejected");

        // A3: the identical message cannot be relayed a second time, so the forged message is
        // recorded exactly like a real one.
        vm.prank(aliased);
        vm.expectRevert(bytes("CrossDomainMessenger: message has already been relayed"));
        ICrossDomainMessenger(L2_CDM).relayMessage(nonce, l1Bridge, L2_BRIDGE, 0, 200_000, finalize);
    }

    /// @dev The PoC, part 2: the value path on L2 is `finalizeBridgeERC20`, which mints. The token is
    ///      deployed by this test and its `mint` is bridge-only, so what is proven is the
    ///      authorisation -- the same call against a listed OptimismMintableERC20 would mint that
    ///      token's supply instead.
    function test_POC_finalizeBridgeERC20_mints_unbacked_supply() public {
        _onL2();
        address aliased = AddressAliasHelper.applyL1ToL2Alias(l1Cdm);
        uint256 amount = 1_000_000 ether;

        MintableToken token = new MintableToken(SEPOLIA_WETH, L2_BRIDGE);
        assertEq(token.balanceOf(ATTACKER), 0, "attacker started with a balance");

        bytes memory finalize = abi.encodeCall(
            IStandardBridge.finalizeBridgeERC20, (address(token), SEPOLIA_WETH, l1Bridge, ATTACKER, amount, "")
        );
        uint256 nonce = ICrossDomainMessenger(L2_CDM).messageNonce();

        vm.prank(aliased);
        (bool ok,) = L2_CDM.call(
            abi.encodeCall(
                ICrossDomainMessenger.relayMessage, (nonce, l1Bridge, L2_BRIDGE, 0, 400_000, finalize)
            )
        );
        assertTrue(ok, "relay rejected");

        assertEq(token.balanceOf(ATTACKER), amount, "attacker did not receive the mint");
        assertEq(token.totalSupply(), amount, "supply did not grow");
    }

    /// @dev And the negative control for the PoC's premise: the same call from any other address,
    ///      including one that merely looks like the alias, is refused.
    function test_POC_premise_holds_only_for_the_exact_alias() public {
        _onL2();
        address aliased = AddressAliasHelper.applyL1ToL2Alias(l1Cdm);
        address nearMiss = address(uint160(aliased) + 1);

        assertTrue(AddressAliasHelper.undoL1ToL2Alias(nearMiss) != l1Cdm, "near miss aliases back");

        vm.prank(nearMiss);
        vm.expectRevert();
        ICrossDomainMessenger(L2_CDM).relayMessage(
            1,
            l1Bridge,
            L2_BRIDGE,
            0,
            200_000,
            abi.encodeCall(IStandardBridge.finalizeBridgeETH, (ATTACKER, ATTACKER, 0, ""))
        );
    }
}
