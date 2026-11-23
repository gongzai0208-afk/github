// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {NaiveReceiverPool} from "pool/NaiveReceiverPool.sol";
import {BasicForwarder} from "pool/BasicForwarder.sol";
import {WETH} from "solmate/tokens/WETH.sol";

/// @dev Minimal receiver used only by the invariant suite. It implements the
///      ERC-3156 callback the pool calls; the production victim fixture is not
///      needed here.
contract TestReceiver is IERC3156FlashBorrower {
    address public immutable pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == pool, "only pool");
        IERC20(token).approve(pool, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Drives deposit / withdraw / flashLoan at random. The receiver initiates
///      its own loan, which is the one path the F-01 fix keeps open, so the same
///      handler runs against both the reviewed code and the fixed tree.
contract NaiveHandler is Test {
    NaiveReceiverPool public pool;
    WETH public weth;
    TestReceiver public receiver;

    address public feeReceiver;
    address[2] public users;

    constructor(NaiveReceiverPool pool_, WETH weth_, TestReceiver receiver_, address feeReceiver_) {
        pool = pool_;
        weth = weth_;
        receiver = receiver_;
        feeReceiver = feeReceiver_;
        users = [address(0xB1), address(0xB2)];
    }

    function deposit(uint256 userSeed, uint256 amount) external {
        address user = users[userSeed % 2];
        amount = bound(amount, 1, 10 ether);
        vm.deal(user, amount);
        vm.prank(user);
        pool.deposit{value: amount}();
    }

    function withdraw(uint256 userSeed, uint256 amount) external {
        address user;
        if (userSeed % 3 == 0) {
            user = feeReceiver;
        } else {
            user = users[userSeed % 2];
        }
        uint256 bal = pool.deposits(user);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(user);
        try pool.withdraw(amount, payable(user)) {} catch {}
    }

    function flashLoan() external {
        vm.prank(address(receiver));
        try pool.flashLoan(receiver, address(weth), 0, "") {} catch {}
    }
}

/// @notice Invariant suite for NaiveReceiverPool (run with `FOUNDRY_PROFILE=invariant`).
/// @dev Holds on both the reviewed code and the fixed tree:
///        1. `totalDeposits` equals the sum of the individual deposits;
///        2. the pool's WETH balance equals what it owes depositors.
contract NaiveReceiverInvariants is Test {
    address constant FEE_RECEIVER = address(0xFEED);

    WETH weth;
    BasicForwarder forwarder;
    NaiveReceiverPool pool;
    TestReceiver receiver;
    NaiveHandler handler;

    function setUp() public {
        vm.deal(FEE_RECEIVER, 1_000 ether);
        vm.prank(FEE_RECEIVER);
        weth = new WETH();
        forwarder = new BasicForwarder();
        vm.prank(FEE_RECEIVER);
        pool = new NaiveReceiverPool{value: 1_000 ether}(
            address(forwarder),
            payable(address(weth)),
            FEE_RECEIVER
        );

        receiver = new TestReceiver(address(pool));
        vm.deal(FEE_RECEIVER, 20 ether);
        vm.startPrank(FEE_RECEIVER);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(receiver), 10 ether);
        vm.stopPrank();

        handler = new NaiveHandler(pool, weth, receiver, FEE_RECEIVER);
        targetContract(address(handler));
    }

    function invariant_totalDepositsMatchesSum() public view {
        uint256 sum = pool.deposits(FEE_RECEIVER) + pool.deposits(address(receiver))
            + pool.deposits(address(0xB1)) + pool.deposits(address(0xB2));
        assertEq(pool.totalDeposits(), sum, "totalDeposits equals the sum of deposits");
    }

    function invariant_poolHoldsWhatItOwes() public view {
        assertEq(weth.balanceOf(address(pool)), pool.totalDeposits(), "pool WETH == deposits owed");
    }
}
