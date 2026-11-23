// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StakingRewards} from "pool/StakingRewards.sol";

contract MintableToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Drives stake / withdraw / getReward / notify / warp at random.
///      `paid`, `funded` and `donated` are ghost counters: the invariant
///      compares them against the pool's actual token balance, so a payout that
///      is not backed by funding shows up immediately.
contract StakingHandler is Test {
    StakingRewards public pool;
    MintableToken public staking;
    MintableToken public reward;

    address public owner = address(0xA11CE0);
    address[3] public actors;
    uint256 public constant DURATION = 100;

    uint256 public paid; // reward tokens actually transferred out
    uint256 public funded; // reward tokens successfully committed via notify
    uint256 public donated; // reward tokens sent to the pool but rejected by notify

    constructor(StakingRewards pool_, MintableToken staking_, MintableToken reward_) {
        pool = pool_;
        staking = staking_;
        reward = reward_;
        actors = [address(0xA1), address(0xB2), address(0xC3)];
        for (uint256 i = 0; i < 3; i++) {
            staking.mint(actors[i], 1_000e18);
        }
        reward.mint(owner, 10_000e18);
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.startPrank(actor);
        staking.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = pool.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        try pool.withdraw(amount) {} catch {}
    }

    function getReward(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 before = reward.balanceOf(actor);
        vm.prank(actor);
        try pool.getReward() {} catch {}
        paid += reward.balanceOf(actor) - before;
    }

    function notify(uint256 amount) external {
        uint256 bal = reward.balanceOf(owner);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.startPrank(owner);
        reward.transfer(address(pool), amount);
        try pool.notifyRewardAmount(amount, DURATION) {
            funded += amount;
        } catch {
            donated += amount;
        }
        vm.stopPrank();
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 7 days));
    }
}

/// @notice Invariant suite for StakingRewards (run with `FOUNDRY_PROFILE=invariant`).
/// @dev These hold on both the reviewed code and the fixed tree, so a failure is a
///      regression, not a known finding:
///        1. the pool holds exactly what users staked;
///        2. every reward token is accounted for: balance + paid == funded + donated.
contract StakingInvariants is Test {
    StakingRewards pool;
    MintableToken staking;
    MintableToken reward;
    StakingHandler handler;

    function setUp() public {
        staking = new MintableToken();
        reward = new MintableToken();
        vm.prank(address(0xA11CE0));
        pool = new StakingRewards(address(staking), address(reward), address(0xA11CE0));
        handler = new StakingHandler(pool, staking, reward);
        targetContract(address(handler));
    }

    function invariant_stakingBalanceMatchesTotalStaked() public view {
        assertEq(
            staking.balanceOf(address(pool)),
            pool.totalStaked(),
            "pool holds exactly the staked principal"
        );
    }

    function invariant_rewardsAreConserved() public view {
        assertEq(
            reward.balanceOf(address(pool)) + handler.paid(),
            handler.funded() + handler.donated(),
            "reward tokens in the pool plus paid out equals funded plus donated"
        );
    }
}
