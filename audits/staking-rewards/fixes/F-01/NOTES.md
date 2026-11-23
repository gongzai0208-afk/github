# StakingRewards F-01 patch — global liability

`notifyRewardAmount` now subtracts a **global** `outstanding` liability before accepting a new rate.
`outstanding` is increased in `updateReward` by `rewardRate × elapsed` and decreased in `getReward` by the
amount paid out.

**Why not a per-user accumulator?** `notifyRewardAmount` calls `updateReward(address(0))`, which settles
nobody, so `rewards[alice]` is still 0 at the moment of the check. A per-user variable would leave the hole
open — the PoC would not even fail.

**Does the fixed state still have a hole?** `outstanding` only ever moves by amounts the contract owes, and
`getReward` settles exactly the paid amount. If `rewardToken == stakingToken`, staked principal is excluded
before the comparison.

```bash
forge test --remappings 'pool/=fixes/F-01/src/' --match-test test_PoC_budgetDoubleSpent
# expect: [FAIL: RewardTooHigh()]
```
