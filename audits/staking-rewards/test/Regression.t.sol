// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StakingRewards} from "pool/StakingRewards.sol";

contract Mintable is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Regression tests for the combined patch (fixes/ALL)
/// @notice F-01 and F-02 both edit the `updateReward` modifier and were previously
///         only ever tested one at a time. This suite runs them together.
///
///         - `test_regression_*` — normal staking behaviour, valid on any build.
///         - `test_regression_patch_*` — only meaningful once the findings are
///           fixed; skipped on the unpatched sources so `forge test` stays green.
///
///         Run against the combined patch:
///         `forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol`
contract StakingRewardsRegression is Test {
    Mintable staking;
    Mintable reward;
    StakingRewards pool;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BUDGET = 100e18;
    uint256 constant DURATION = 100;
    uint256 constant STAKE = 10e18;

    bool patched;

    function setUp() public {
        staking = new Mintable();
        reward = new Mintable();

        vm.startPrank(owner);
        pool = new StakingRewards(address(staking), address(reward), owner);
        reward.mint(address(pool), BUDGET);
        pool.notifyRewardAmount(BUDGET, DURATION);
        vm.stopPrank();

        staking.mint(alice, STAKE);
        staking.mint(bob, STAKE);

        // Probe: F-03 makes exit() a no-op for a zero-balance caller; before the
        // fix it reverts with ZeroAmount.
        vm.prank(bob);
        try pool.exit() {
            patched = true;
        } catch {
            patched = false;
        }
    }

    modifier whenPatched() {
        if (!patched) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _stake(address who) internal {
        vm.startPrank(who);
        staking.approve(address(pool), STAKE);
        pool.stake(STAKE);
        vm.stopPrank();
    }

    /// @dev Low-level call: `effectivePeriodFinish()` only exists after the F-02
    ///      patch, so a typed call would not compile against the reviewed sources.
    function _effectivePeriodFinish() internal view returns (bool ok, uint256 value) {
        bytes memory data;
        (ok, data) = address(pool).staticcall(abi.encodeWithSignature("effectivePeriodFinish()"));
        if (ok) value = abi.decode(data, (uint256));
    }

    // ------------------------------------------------------- always-on flows

    /// @dev Staking for the whole period still pays the whole budget.
    function test_regression_fullPeriodPaysBudget() public {
        _stake(alice);
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        pool.getReward();

        assertEq(reward.balanceOf(alice), BUDGET, "staker receives the entire budget");
        assertEq(reward.balanceOf(address(pool)), 0, "nothing left in the pool");
    }

    /// @dev A second staker joining mid-period still splits pro rata.
    function test_regression_twoStakersSplitProRata() public {
        _stake(alice);
        vm.warp(block.timestamp + 50);
        _stake(bob);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        pool.getReward();
        vm.prank(bob);
        pool.getReward();

        // alice carried the pool alone for half the period, then split the second
        // half with bob: 50 + 25 = 75; bob gets 25.
        assertEq(reward.balanceOf(alice), 75e18, "alice: solo half + half of the split half");
        assertEq(reward.balanceOf(bob), 25e18, "bob: his share of the second half");
    }

    /// @dev The 1-wei-staker pattern the earlier (wrong) F-02 patch made
    ///      profitable: staking after an idle window and claiming in the same
    ///      block must not pay the frozen budget.
    function test_regression_oneWeiInstantClaimEarnsNothing() public {
        vm.warp(block.timestamp + 50); // idle window

        vm.startPrank(bob);
        staking.approve(address(pool), 1);
        pool.stake(1);
        pool.getReward();
        vm.stopPrank();

        assertLt(reward.balanceOf(bob), 1e15, "instant claim after staking 1 wei is ~0");
    }

    // ------------------------------------------------- fix-only regressions

    /// @dev F-01: a funded period can no longer be re-committed while its rewards
    ///      are earned but unclaimed — and the first period still pays out.
    function test_regression_patch_secondNotifyRejected() public whenPatched {
        _stake(alice);
        vm.warp(block.timestamp + DURATION);

        vm.prank(owner);
        vm.expectRevert(StakingRewards.RewardTooHigh.selector);
        pool.notifyRewardAmount(BUDGET, DURATION);

        vm.prank(alice);
        pool.getReward();
        assertEq(reward.balanceOf(alice), BUDGET, "the legitimate period still pays");
    }

    /// @dev F-02: an idle window freezes the period instead of stranding half the
    ///      budget. The end time moves by exactly the idle time, which is the
    ///      trade-off the report discloses.
    function test_regression_patch_idleFreezesPeriod() public whenPatched {
        uint256 endBefore = pool.periodFinish();

        // During the idle window the stored value is stale; the view must already
        // report the extended end, or a front end shows the pool as finished.
        vm.warp(block.timestamp + 50);
        assertEq(pool.periodFinish(), endBefore, "stored periodFinish only moves on a transaction");

        (bool okView, uint256 eff) = _effectivePeriodFinish();
        assertTrue(okView, "effectivePeriodFinish() exists after the patch");
        assertEq(eff, endBefore + 50, "view accounts for the idle time");

        _stake(alice);
        assertEq(pool.periodFinish(), endBefore + 50, "period end moved by the idle time");

        (bool okAfter, uint256 effAfter) = _effectivePeriodFinish();
        assertTrue(okAfter, "effectivePeriodFinish() still callable");
        assertEq(effAfter, pool.periodFinish(), "view agrees once settled");

        // 25 seconds into the frozen period, alice has earned 25 tokens. The
        // merged tree must count that as a liability: re-committing the whole
        // budget would promise the same tokens twice (F-01) even though the idle
        // window was frozen away (F-02).
        vm.warp(block.timestamp + 25);
        vm.prank(owner);
        vm.expectRevert(StakingRewards.RewardTooHigh.selector);
        pool.notifyRewardAmount(BUDGET, DURATION);

        vm.warp(block.timestamp + 75);
        vm.prank(alice);
        pool.getReward();

        assertEq(reward.balanceOf(alice), BUDGET, "no budget stranded by the idle window");
        assertEq(reward.balanceOf(address(pool)), 0, "pool emptied");
    }

    /// @dev F-03: exit() with nothing staked pays the rewards already earned
    ///      instead of reverting before getReward().
    function test_regression_patch_exitPaysAfterFullWithdraw() public whenPatched {
        _stake(alice);
        vm.warp(block.timestamp + DURATION);

        vm.startPrank(alice);
        pool.withdraw(STAKE); // rewards stay claimable, balance is now 0
        pool.exit(); // must not revert, must pay
        vm.stopPrank();

        assertEq(reward.balanceOf(alice), BUDGET, "exit() paid the accrued rewards");
        assertEq(staking.balanceOf(alice), STAKE, "stake returned");
    }
}
