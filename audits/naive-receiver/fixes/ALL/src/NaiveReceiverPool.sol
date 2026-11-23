// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FlashLoanReceiver} from "./FlashLoanReceiver.sol";
import {Multicall} from "./Multicall.sol";
import {WETH} from "solmate/tokens/WETH.sol";

contract NaiveReceiverPool is Multicall, IERC3156FlashLender {
    uint256 private constant FIXED_FEE = 1e18; // not the cheapest flash loan
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    WETH public immutable weth;
    address public immutable trustedForwarder;
    address public immutable feeReceiver;

    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    error RepayFailed();
    error UnsupportedCurrency();
    error CallbackFailed();
    error Unauthorized();

    constructor(address _trustedForwarder, address payable _weth, address _feeReceiver) payable {
        weth = WETH(_weth);
        trustedForwarder = _trustedForwarder;
        feeReceiver = _feeReceiver;
        _deposit(msg.value);
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token == address(weth)) return weth.balanceOf(address(this));
        return 0;
    }

    function flashFee(address token, uint256) external view returns (uint256) {
        if (token != address(weth)) revert UnsupportedCurrency();
        return FIXED_FEE;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        if (token != address(weth)) revert UnsupportedCurrency();

        // F-01 fix: the fee is paid by the receiver, so the receiver (or someone it
        // has authorised) must be the initiator. Without this anyone can open loans
        // against any receiver and drain it one fixed fee at a time.
        if (msg.sender != address(receiver)) revert Unauthorized();

        // Transfer WETH and handle control to receiver
        weth.transfer(address(receiver), amount);
        totalDeposits -= amount;

        if (receiver.onFlashLoan(msg.sender, address(weth), amount, FIXED_FEE, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed();
        }

        uint256 amountWithFee = amount + FIXED_FEE;
        weth.transferFrom(address(receiver), address(this), amountWithFee);
        totalDeposits += amountWithFee;

        deposits[feeReceiver] += FIXED_FEE;

        return true;
    }

    function withdraw(uint256 amount, address payable receiver) external {
        // Reduce deposits
        deposits[_msgSender()] -= amount;
        totalDeposits -= amount;

        // Transfer ETH to designated receiver
        weth.transfer(receiver, amount);
    }

    function deposit() external payable {
        _deposit(msg.value);
    }

    function _deposit(uint256 amount) private {
        weth.deposit{value: amount}();

        deposits[_msgSender()] += amount;
        totalDeposits += amount;
    }

    /// @dev F-02 fix: the last 20 bytes of calldata are only trustworthy when the call
    ///      comes straight from the forwarder, which appends `request.from` there.
    ///      A multicall sub-call is a delegatecall, so `msg.sender` is still the
    ///      forwarder while the tail is whatever the caller put in the payload -
    ///      from inside `_msgSender()` the two cases are indistinguishable. The
    ///      separation must therefore happen at this entry point: forwarder-originated
    ///      multicall payloads are rejected rather than being read as a sender.
    ///      Plain (non-meta-tx) multicall keeps working, because there `msg.sender`
    ///      is the caller itself and no tail is trusted.
    function multicall(bytes[] calldata data) external override returns (bytes[] memory results) {
        if (msg.sender == trustedForwarder) revert Unauthorized();

        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            results[i] = Address.functionDelegateCall(address(this), data[i]);
        }
    }

    function _msgSender() internal view override returns (address) {
        if (msg.sender == trustedForwarder && msg.data.length >= 20) {
            return address(bytes20(msg.data[msg.data.length - 20:]));
        } else {
            return super._msgSender();
        }
    }
}
