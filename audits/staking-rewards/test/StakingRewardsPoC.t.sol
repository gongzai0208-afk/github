// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StakingRewards} from "pool/StakingRewards.sol";

contract MintableToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * PoC — StakingRewards (JohnDonuttt/staking-rewards, commit b7979864, src/StakingRewards.sol)
 *
 * No published findings exist for this repository, so the assertions below are the
 * only statement of harm: each one encodes the invariant that is broken (budget
 * conservation, fully-paid periods, exit() as a safe no-op), not merely "a call
 * returned".
 */
contract StakingRewardsPoC is Test {
    MintableToken staking;
    MintableToken reward;
    StakingRewards pool;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    uint256 constant REWARD_BUDGET = 100e18;
    uint256 constant DURATION = 100; // seconds
    uint256 constant STAKE_AMOUNT = 10e18;

    function setUp() public {
        staking = new MintableToken();
        reward = new MintableToken();

        vm.startPrank(owner);
        pool = new StakingRewards(address(staking), address(reward), owner);
        reward.mint(address(pool), REWARD_BUDGET); // owner 预先充值奖励储备
        pool.notifyRewardAmount(REWARD_BUDGET, DURATION); // rate = 1e18 / s
        vm.stopPrank();

        staking.mint(alice, STAKE_AMOUNT);
    }

    /// F-02：periodFinish 之前无人质押的时段，奖励既不累积、也不分给任何人
    function test_PoC_rewardsDroppedWhileNoStakers() public {
        // 前 50 秒：池子空转（totalStaked == 0）
        vm.warp(block.timestamp + 50);

        vm.startPrank(alice);
        staking.approve(address(pool), STAKE_AMOUNT);
        pool.stake(STAKE_AMOUNT); // 此刻 rewardPerToken() 因 totalStaked==0 直接返回 stored
        vm.stopPrank();

        // 后 50 秒：alice 独自承担，到期领取
        vm.warp(block.timestamp + 150); // past the original period end
        vm.prank(alice);
        pool.getReward();

        uint256 aliceGot = reward.balanceOf(alice);
        uint256 stranded = reward.balanceOf(address(pool));

        console.log("reward budget         :", REWARD_BUDGET);
        console.log("alice received        :", aliceGot);
        console.log("stranded in contract  :", stranded);

        // 不变式：预算 == 已发放 + 滞留；这里已发放只有后半段
        assertEq(aliceGot, 50e18, "alice only earns the half she was actually staking through");
        assertEq(stranded, 50e18, "the first half's budget stays in the contract");
        assertEq(aliceGot + stranded, REWARD_BUDGET, "budget is conserved, but half is unreachable");
    }

    /// F-01：notifyRewardAmount 的余额校验不含「已累计但未领取」的负债，
    ///       同一笔余额可以被承诺给两个周期 —— 后到者的奖励无法兑付
    function test_PoC_budgetDoubleSpent_secondStakerUnpaid() public {
        address bob = makeAddr("bob");
        staking.mint(bob, STAKE_AMOUNT);

        // 第 1 周期：alice 全程质押，应得 100e18（= 整个储备），但还没领取
        vm.startPrank(alice);
        staking.approve(address(pool), STAKE_AMOUNT);
        pool.stake(STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);

        // owner 没有追加任何资金，只是把「同样的 100e18 预算」再发一轮：
        // 校验只对比 rewardRate*duration 与当前余额，不看已累计未领取的 100e18 负债
        vm.prank(owner);
        pool.notifyRewardAmount(REWARD_BUDGET, DURATION); // 通过了

        // alice 把储备全部领走
        vm.prank(alice);
        pool.getReward();
        assertEq(reward.balanceOf(alice), REWARD_BUDGET, "alice drains the entire reserve");

        // bob 在第 2 周期质押并等满一个周期
        vm.startPrank(bob);
        staking.approve(address(pool), STAKE_AMOUNT);
        pool.stake(STAKE_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);

        uint256 bobEarned = pool.earned(bob);
        uint256 reserve = reward.balanceOf(address(pool));

        console.log("alice paid            :", reward.balanceOf(alice));
        console.log("bob accrued (unpaid)  :", bobEarned);
        console.log("reserve left          :", reserve);

        assertGt(bobEarned, 0, "bob really accrued rewards in period 2");
        assertEq(reserve, 0, "but the reserve was already spent on period 1");

        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance：会计资不抵债
        pool.getReward();
    }

    /// F-03：exit() 对没有任何质押的用户直接 revert（应为 no-op 而不是失败）
    function test_PoC_exitRevertsWithoutStake() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        pool.exit();
    }
}
