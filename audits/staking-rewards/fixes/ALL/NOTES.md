# fixes/ALL — every finding fixed at once

This tree is the union of `fixes/F-01`, `F-02` and `F-03`, produced by a per-file
three-way merge (base = `src/`). Unlike the TraitForge tree, this one **required a
hand resolution**: F-01 and F-02 edit the same `updateReward` modifier, and
`git merge-file` reports a conflict there.

## The conflict and how it was resolved

F-01 adds a global-liability accumulator inside the modifier:

```solidity
if (totalStaked > 0 && applicable > lastUpdateTime) {
    outstanding += (applicable - lastUpdateTime) * rewardRate;
}
```

F-02 replaces the tail of the same modifier (`lastUpdateTime = applicable;`) with
a freeze branch that moves both `lastUpdateTime` and `periodFinish` while the pool
is empty. The resolution keeps both semantics and makes them mutually exclusive:

```solidity
rewardPerTokenStored = rewardPerToken();
if (totalStaked > 0) {
    lastUpdateTime = lastTimeRewardApplicable();   // F-02: normal path
} else {
    uint256 idle = block.timestamp - lastUpdateTime;
    if (idle > 0) {
        lastUpdateTime = block.timestamp;          // F-02: freeze
        periodFinish += idle;
    }
}
```

Because the freeze branch is only taken when `totalStaked == 0`, and the F-01
accrual only runs when `totalStaked > 0`, `outstanding` is never incremented for
an idle window — the freeze does not double-count, and the liability check in
`notifyRewardAmount` still sees every token that was actually earned.

Re-running the merge today reproduces the same conflict (the `<<<<<<<` block over
`lastUpdateTime`), which is why this file exists: the resolution is a decision,
not a mechanical result.

The F-02 side of the patch also adds `effectivePeriodFinish()` and the
`PeriodExtended` event. They sit outside the conflicting hunk, so a fresh merge
includes them unchanged; only the modifier body above is hand-written.

## How to run it

```bash
forge test --remappings 'pool/=fixes/ALL/src/'
# expect: 3 failed, 6 passed (the 6 are the regression suite)

forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 6 passed
```

The regression suite covers the pair that was never tested together before:
F-01's second-period rejection and F-02's idle freeze, plus the 1-wei instant
claim the earlier (wrong) F-02 patch made profitable.

## Limits

- Not a proposed release: no migration, no storage-layout review.
- The F-02 patch changes the meaning of `periodFinish` (it moves with idle time).
  That trade-off is disclosed in `fixes/F-02/NOTES.md` and in the report.
