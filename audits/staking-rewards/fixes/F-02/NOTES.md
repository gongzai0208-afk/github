# StakingRewards F-02 patch

## F-02 — idle periods no longer strand the budget

`updateReward` freezes the period while `totalStaked == 0`: both `lastUpdateTime` and `periodFinish`
move forward by the idle time. Nothing accrues to an empty pool, and nothing is stranded either.

**This replaced an earlier, wrong patch.** The first version moved only `lastUpdateTime`. That left
`periodFinish` in the past, so the next staker collected the whole remaining budget the moment they
staked — the patch removed the stranding and introduced a theft. The fix-fail run showed
the assertion failing at `100000000000000000000 != 50000000000000000000`, which was the symptom of the new bug, not evidence that the original one was fixed.
Anyone reviewing an earlier copy of this tree should treat that version as broken.

**Cost of this patch (also stated in the report).** `periodFinish` now moves with every idle
second, so the announced end of the period is not the real end any more. A late staker gets a
longer effective period than advertised. The report offers the alternative (let the owner recover
the stranded part) for teams that need a fixed timeline.

**The patch also adds a read path, because storage is stale during the idle window.** The stored
`periodFinish` only moves when a transaction runs, so between calls a client — or the
`PeriodNotFinished` guard in `notifyRewardAmount` — sees the old end and can treat the pool as
finished while it is only frozen. This tree therefore adds:

```solidity
function effectivePeriodFinish() external view returns (uint256); // storage + pending idle time
event PeriodExtended(uint256 newPeriodFinish);                    // emitted when it freezes
```

Consumers must read the view; the report says so. Without it the fix is correct on-chain and
wrong in every front end, which is a deployment cost of exactly the same kind as the moved end
time, and it would not be visible from the contract API alone.

## Verify

```bash
forge test --remappings 'pool/=fixes/F-02/src/' --match-test test_PoC_rewardsDroppedWhileNoStakers
# expect: [FAIL: alice only earns the half she was actually staking through: 100000000000000000000 != 50000000000000000000]
```

F-03 has its own tree (`fixes/F-03/`); it is no longer combined with this one.

**Does the fixed state still have a hole?**

- A staker who is alone in the pool earns the whole remaining budget over the remaining duration.
  That is staking economics, not a defect: they carry the position for that time.
- A 1-wei staker who stakes after the idle window and claims **immediately** earns ~0, because the
  period is frozen, not pre-paid. That is the specific pattern the earlier patch made profitable;
  `test/Regression.t.sol` keeps it as a permanent check.
- Invariant: cumulative payouts cannot exceed the funded budget, because `outstanding` is only ever
  increased by `rewardRate × elapsed` and decreased by the amount transferred.
