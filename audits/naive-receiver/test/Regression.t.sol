// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall} from "pool/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "pool/FlashLoanReceiver.sol";
import {BasicForwarder} from "pool/BasicForwarder.sol";
import {WETH} from "solmate/tokens/WETH.sol";

/// @title Regression tests for the combined patch (fixes/ALL)
/// @notice - `test_regression_*` — normal pool operations, valid on any build.
///         - `test_regression_patch_*` — only meaningful once both findings are
///           fixed; skipped on the unpatched sources.
///
///         Run against the combined patch:
///         `forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol`
contract NaiveReceiverRegression is Test {
    address deployer = makeAddr("deployer");

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;
    uint256 constant FIXED_FEE = 1e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    bool patched;

    function setUp() public {
        startHoax(deployer);
        weth = new WETH();
        forwarder = new BasicForwarder();
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(address(weth)), deployer);

        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);
        vm.stopPrank();

        // Probe: F-02 rejects a multicall whose msg.sender is the trusted
        // forwarder; before the fix that call is accepted (and does nothing).
        bytes[] memory empty = new bytes[](0);
        vm.prank(address(forwarder));
        try pool.multicall(empty) {
            patched = false;
        } catch {
            patched = true;
        }
    }

    modifier whenPatched() {
        if (!patched) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _signRequest(BasicForwarder.Request memory request, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", forwarder.domainSeparator(), forwarder.getDataHash(request)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------- always-on flows

    /// @dev A receiver that initiates its own flash loan is still served, and the
    ///      fee still moves from the receiver to the fee receiver's deposit.
    function test_regression_selfInitiatedFlashLoan() public {
        uint256 depositBefore = pool.deposits(deployer);

        vm.prank(address(receiver));
        pool.flashLoan(receiver, address(weth), 0, "");

        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER - FIXED_FEE, "receiver paid one fee");
        assertEq(pool.deposits(deployer) - depositBefore, FIXED_FEE, "fee credited to the fee receiver");
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL + FIXED_FEE, "pool received the fee");
    }

    /// @dev Plain deposit/withdraw round-trip.
    function test_regression_depositAndWithdraw() public {
        vm.deal(deployer, 2 ether);
        vm.startPrank(deployer);
        pool.deposit{value: 1 ether}();
        assertEq(pool.deposits(deployer), WETH_IN_POOL + 1 ether, "deposit credited");
        pool.withdraw(1 ether, payable(deployer));
        vm.stopPrank();

        assertEq(pool.deposits(deployer), WETH_IN_POOL, "deposit debited");
        assertEq(weth.balanceOf(deployer), 1 ether, "withdrawal paid out");
    }

    /// @dev A single forwarded call (not a multicall) still authenticates
    ///      `request.from` through the calldata tail — the F-02 patch only rejects
    ///      multicall payloads arriving from the forwarder.
    function test_regression_forwardedSingleCall() public {
        (address user, uint256 pk) = makeAddrAndKey("forwarded-user");
        vm.deal(user, 1 ether);
        vm.prank(user);
        pool.deposit{value: 1 ether}();

        bytes memory call = abi.encodeCall(NaiveReceiverPool.withdraw, (0.4 ether, payable(user)));
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: user,
            target: address(pool),
            value: 0,
            gas: 1_000_000,
            nonce: 0,
            data: call,
            deadline: block.timestamp + 1 days
        });

        vm.prank(user);
        bool ok = forwarder.execute(request, _signRequest(request, pk));
        assertTrue(ok, "forwarded single call executes");

        assertEq(pool.deposits(user), 0.6 ether, "deposit debited for the forwarded user");
        assertEq(weth.balanceOf(user), 0.4 ether, "withdrawal reached the forwarded user");
    }

    // ------------------------------------------------- fix-only regressions

    /// @dev F-02: the spoofed multicall is now rejected, the victim's deposit is
    ///      intact, and nothing reaches the attacker.
    function test_regression_patch_spoofedMulticallRejected() public whenPatched {
        (address attacker, uint256 attackerPk) = makeAddrAndKey("attacker");
        address victim = deployer; // the 1,000 WETH depositor

        bytes memory withdrawal = abi.encodeCall(NaiveReceiverPool.withdraw, (WETH_IN_POOL, payable(attacker)));
        bytes memory spoofed = abi.encodePacked(withdrawal, victim);
        bytes[] memory calls = new bytes[](1);
        calls[0] = spoofed;

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: attacker,
            target: address(pool),
            value: 0,
            gas: 1_000_000,
            nonce: 0,
            data: abi.encodeCall(Multicall.multicall, (calls)),
            deadline: block.timestamp + 1 days
        });

        vm.prank(attacker);
        bool ok = forwarder.execute(request, _signRequest(request, attackerPk));

        assertFalse(ok, "forwarder reports the inner multicall as failed");
        assertEq(pool.deposits(victim), WETH_IN_POOL, "victim deposit untouched");
        assertEq(weth.balanceOf(attacker), 0, "attacker received nothing");
    }
}
