# Smart Contract Security Review — StakingRewards

**Target:** `src/StakingRewards.sol` (159 lines)
**Source:** `https://github.com/JohnDonuttt/staking-rewards` at commit `b7979864b1f6cc0091838199a0befaab9207a1f4` (`src/StakingRewards.sol` blob `ecccfbbe1f84f6d54d118c77094ec1c6692b429e`; the file here is byte-identical, sha256 `b29bf4b3…`)
**Compiler:** solc 0.8.25, OpenZeppelin Contracts 5.2.0
**Date:** November 2026

---

## 1. Executive Summary

A single-contract staking pool: users stake one token, earn another at a rate spread over a reward period, using the Synthetix-style `rewardPerToken` accumulator.

Three issues are reported: **1 High, 1 Medium, 1 Low**. The High is an accounting one — the contract can promise the same tokens to two reward periods, and the second set of users finds nothing left to claim. All three are reproduced by tests in [`test/`](test/).

| ID | Severity | Title |
|---|---|---|
| F-01 | High | Reward balance check ignores liabilities already accrued, allowing the same tokens to be promised twice |
| F-02 | Medium | Reward budget accruing while nobody is staked is permanently stranded |
| F-03 | Low | `exit()` reverts for a user with no stake instead of doing nothing |

## 2. Scope

| File | Lines | SHA-256 |
|---|---|---|
| `src/StakingRewards.sol` | 159 | `b29bf4b37fbe0fe0bbd849d50b7f9616a1bfd2c87731fafcad866fe6096aadd4` |
| `lib/openzeppelin-contracts` | — | OpenZeppelin 5.2.0 |
| `lib/forge-std` | — | test harness only |

The contract is self-contained aside from ERC-20 dependencies. No proxy, no upgradeability, no oracle.

## 3. Severity Classification

The same three definitions are used in all three reviews in this repository:

| Severity | Definition |
|---|---|
| **High** | Loss of user funds, or a broken core invariant, reachable through the documented flow with well-formed input, where neither the victim's own wrong amount nor a privileged role setting an invalid value is required. |
| **Medium** | Bounded or self-inflicted value loss (an overpayment, stranded dust, an overcharge at a generation boundary), economic distortion, or denial of service under normal use. |
| **Low** | Requires a privileged role to set an invalid value first (misconfiguration), a dead safety mechanism, or no direct fund loss. |

F-01 is High under this rule: `notifyRewardAmount` is the documented way to start a period, the call is well-formed, and no privileged *value* is needed — the check that should reject an unfunded commitment exists and is wrong, so users of the second period cannot be paid through no fault of their own.

A privileged call still counts as the documented flow when the contract itself validates that input; a wrong value is excluded from High only where the code performs no check on it. That is what separates this finding from a misconfiguration such as setting an unchecked address or percentage (the Low findings in the TraitForge report).

## 4. Findings

### F-01 — Reward balance check ignores liabilities already accrued, allowing the same tokens to be promised twice

**Severity:** High
**Location:** `src/StakingRewards.sol` L145–151 (`notifyRewardAmount` balance check), against L74–77 (`earned`)

**Description.**
When a new reward period starts, the contract checks that it holds enough tokens to cover the new rate:

```solidity
// L145-151
uint256 balance = rewardToken.balanceOf(address(this));
if (address(rewardToken) == address(stakingToken)) {
    balance -= totalStaked;
}
if (rewardRate * duration > balance) revert RewardTooHigh();
```

`balance` is the raw token balance. It does not subtract the rewards already accrued to users but not yet claimed — those are tracked per user in `rewards[]` and only materialise as transfers when `getReward()` is called. A balance that has been fully earned by period 1 therefore looks untouched, and can be committed again to period 2.

**Impact.**
Two periods are funded by one balance. Users of the first period withdraw their rewards, and the second period's users accrue rewards that cannot be paid: `getReward()` reverts on the ERC-20 transfer. The failure is not detectable at configuration time — `notifyRewardAmount` accepts the second period without complaint.

**Proof of Concept.**
`test_PoC_budgetDoubleSpent_secondStakerUnpaid` in [`test/StakingRewardsPoC.t.sol`](test/StakingRewardsPoC.t.sol).

Sequence: Alice stakes for a full period, accruing the entire 100-token budget but not claiming. The owner calls `notifyRewardAmount` again with the same 100-token budget and no new funding — the call succeeds. Alice claims all 100 tokens. Bob stakes for period 2 and accrues rewards normally.

Observed: Alice paid 100, Bob accrued > 0, reserve left 0, and Bob's `getReward()` reverts with `ERC20InsufficientBalance`.

**Recommendation.**
Reserve accrued liabilities before checking the new commitment:

The check must subtract a **global** liability, not a per-user one. A per-user accumulator does not work here: `notifyRewardAmount` calls `updateReward(address(0))`, which settles nobody, so Alice's `rewards[alice]` is still 0 at that moment and the check would pass exactly as before — the PoC would not even be fixed by a per-user variable.

```solidity
// global liability, updated on every reward-touching call
uint256 public outstanding; // tokens earned but not yet paid out

function updateReward(address account) internal {
    uint256 applicable = lastTimeRewardApplicable();
    if (totalStaked > 0 && applicable > lastUpdateTime) {
        outstanding += (applicable - lastUpdateTime) * rewardRate;
    }
    rewardPerTokenStored = rewardPerToken();
    lastUpdateTime = applicable;
    ...
}

function getReward() public nonDerived updateReward(msg.sender) {
    uint256 reward = rewards[msg.sender];
    if (reward > 0) {
        rewards[msg.sender] = 0;
        outstanding -= reward;          // liability settled
        rewardToken.safeTransfer(msg.sender, reward);
    }
}

// in notifyRewardAmount:
uint256 balance = rewardToken.balanceOf(address(this));
if (address(rewardToken) == address(stakingToken)) balance -= totalStaked;
if (rewardRate * duration > balance - outstanding) revert RewardTooHigh();
```

Ordering matters: `outstanding` has to be brought up to date **before** the new rate is checked, which the `updateReward(address(0))` modifier already does as long as the accumulator is global.

---

### F-02 — Reward budget accruing while nobody is staked is permanently stranded

**Severity:** Medium
**Location:** `src/StakingRewards.sol` L66–72 (`rewardPerToken`), L48–56 (`updateReward`), L137–143 (rollover logic)

**Description.**
While `totalStaked == 0`, `rewardPerToken()` returns the stored value, so time passes without accruing to anyone:

```solidity
// L66-72
if (totalStaked == 0) return rewardPerTokenStored;
uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
```

The next call to any function with the `updateReward` modifier sets `lastUpdateTime` to the current time, so the elapsed interval is silently discarded. The tokens covering that interval stay in the contract, but the rollover path only counts them if the new period starts before `periodFinish`:

```solidity
// L137-143
if (block.timestamp >= periodFinish) {
    rewardRate = reward / duration;
} else {
    uint256 leftover = remaining * rewardRate;
    rewardRate = (reward + leftover) / duration;
}
```

If the period has already ended, the stranded tokens are never folded back into a future period and no function withdraws them.

**Impact.**
Announced rewards are not fully distributed. In the PoC, half of the budget becomes permanently unreachable, which is a direct discrepancy between what the owner advertised and what stakers can earn.

**Proof of Concept.**
`test_PoC_rewardsDroppedWhileNoStakers` in [`test/StakingRewardsPoC.t.sol`](test/StakingRewardsPoC.t.sol).

Sequence: 100 tokens over 100 seconds; nobody stakes for the first 50 seconds; Alice stakes for the remaining 50.

Observed: Alice receives 50, 50 remain stranded in the contract, and the invariant `paid + stranded == budget` holds — the budget is conserved but half is unreachable.

**Recommendation.**
Decide the policy explicitly and encode it:

- pause accrual while nobody is staked (do not consume the period), or
- leave the stranded amount claimable by the owner (`recoverUnclaimed`), or
- roll stranded tokens into the next period unconditionally.

Silently keeping them is the one option that costs users money.

**Deployment cost of the freeze option.** The patch in `fixes/F-02/` takes the first option: while `totalStaked == 0` it advances both `lastUpdateTime` and `periodFinish`. That keeps the budget whole, but it means the announced end of the period is no longer the actual end — every idle second pushes it back. A staker who joins late gets a longer effective period than the one advertised. That is a real behavioural change, not just an implementation detail; the alternative (let the owner recover the stranded part) keeps the timeline and instead gives the owner a claim on user-facing rewards. Both are defensible; silently keeping the tokens is not.

Because the stored `periodFinish` only moves when a transaction runs, it is **stale during the idle window itself**: a UI (or the `PeriodNotFinished` guard in `notifyRewardAmount`) reading storage sees the old end and can show the pool as finished while it is merely frozen. The patch therefore adds `effectivePeriodFinish()` — `periodFinish` plus the pending idle time — and emits `PeriodExtended(newPeriodFinish)` whenever it freezes. Consumers must read the view, not the storage variable; the report states this so the fix is not just correct in the contract and wrong in every client.

---

### F-03 — `exit()` reverts for a user with no stake

**Severity:** Low
**Location:** `src/StakingRewards.sol` L114–117 (`exit`), L93–95 (`withdraw`)

**Description.**
`exit()` calls `withdraw(balanceOf[msg.sender])`, and `withdraw` rejects zero amounts:

```solidity
// L93-95
if (amount == 0) revert ZeroAmount();
```

A user who has already withdrawn but still has unclaimed rewards cannot use `exit()`: it reverts before reaching `getReward()`.

**Impact.**
Denial of a convenience function, and a confusing failure: the user is told their call is invalid when in fact they are owed rewards.

**Proof of Concept.**
`test_PoC_exitRevertsWithoutStake` in [`test/StakingRewardsPoC.t.sol`](test/StakingRewardsPoC.t.sol): a user with zero balance calls `exit()` and receives `ZeroAmount`.

**Recommendation.**
Make the withdrawal conditional inside `exit()`:

```solidity
function exit() external {
    uint256 balance = balanceOf[msg.sender];
    if (balance > 0) withdraw(balance);
    getReward();
}
```

## 5. Out of Scope and Limitations

- Tests use mock ERC-20 tokens; fee-on-transfer and rebasing tokens are not covered. `safeTransfer` usage suggests they were not intended to be supported.
- The owner is **not** assumed malicious. F-01 is reachable through the documented funding flow (`notifyRewardAmount` is how a period is started), so it needs no privileged misbehaviour — only an owner who re-commits a budget that has already been earned.
- **Provenance.** This is the one target in the set with no published answer key: it is a small open-source repository, and no audit, contest report or issue list covering these functions was found at review time. The source was fetched from `raw.githubusercontent.com` and pinned by blob hash (see the header), and the findings were derived from the contract alone. That cuts both ways: nothing here was influenced by a published list, and nothing here has been confirmed by an external reviewer either. Treat the severities as one reviewer's judgement.
- No fuzzing or invariant campaign; all findings come from manual reading plus targeted execution.
- Severity is an assessment, not a fact about deployed code.

## 6. Appendix

```bash
forge test -vv
```

| Test | Finding | Fails when fixed? |
|---|---|---|
| `test_PoC_budgetDoubleSpent_secondStakerUnpaid` | F-01 | **yes** — verified against `fixes/F-01/`, which reverts with `RewardTooHigh()` |
| `test_PoC_rewardsDroppedWhileNoStakers` | F-02 | **yes** — against `fixes/F-02/` (accrual paused while `totalStaked == 0`); assertion now reads `100000000000000000000 != 50000000000000000000` |
| `test_PoC_exitRevertsWithoutStake` | F-03 | **yes** — against its own tree `fixes/F-03/` (not the F-02 tree); the `expectRevert` no longer reverts |

Reproduce the verified case:

```bash
forge test --remappings 'pool/=fixes/F-01/src/' --match-test test_PoC_budgetDoubleSpent
# expect: [FAIL: RewardTooHigh()]
```

### Combined patch

`fixes/ALL/src/` merges all three fixes. F-01 and F-02 both edit the `updateReward` modifier, so applying them one at a time never tested the pair — merging the two trees produced a real conflict in that modifier (F-01 adds the global-liability accrual, F-02 freezes the period while `totalStaked == 0`), which is resolved in `fixes/ALL/`. All three PoCs still fail against the merged tree (`logs/all-poc-fail.txt`), and [`test/Regression.t.sol`](test/Regression.t.sol) checks the flows the fixes must not break: a full-period staker still receives the whole budget, two stakers still split pro rata, a 1-wei staker claiming in the same block still earns ~0, a second unfunded period is rejected, an idle window no longer strands the budget (and moves `periodFinish` by the idle time), a re-commitment made after such a window is still rejected because the accrued liability is counted, and `exit()` pays after a full withdrawal. Run it against the merged tree:

```bash
forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 6 passed
```

On the unpatched sources the same file reports the three fix-only tests as skipped, so `forge test` stays green on the reviewed commit.

### Invariant testing

`test/invariant/StakingInvariants.t.sol` drives `stake`, `withdraw`, `getReward`, `notifyRewardAmount` and time with random actors and amounts, and checks after every call sequence:

| Invariant | What it catches |
|---|---|
| `invariant_stakingBalanceMatchesTotalStaked` | principal accounting drifting from the token balance |
| `invariant_rewardsAreConserved` | `pool balance + paid out == funded + donated` — a payout not backed by funding, or tokens appearing from nowhere |

```bash
forge test --match-path 'test/invariant/*'
# expect: 2 invariants pass (64 runs x 32 depth, 0 reverts)
```

The suite passes on both the reviewed sources and `fixes/ALL`. It is a regression net, not a discovery tool: the handler's `notify` is a single actor making well-formed calls, and the conservation invariant holds until the second, unfunded commitment is made against an already-earned balance — the exact sequence the F-01 PoC drives.
