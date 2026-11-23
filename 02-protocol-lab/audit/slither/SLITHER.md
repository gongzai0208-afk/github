# Static analysis - what Slither reported, and what was done with it

**Tool:** slither 0.11.6, 102 detectors.
**Scope:** `src/` - 8 contracts, 750 lines. `test/`, `script/` and the mocks are excluded.
**Result:** 43 findings on the first run, 39 after the three fixes below landed.

| Run | Findings | Detectors | File |
|---|---:|---:|---|
| before | 43 | 11 | [`slither-before-fixes.txt`](slither-before-fixes.txt) |
| after | 39 | 8 | [`slither.txt`](slither.txt) |

```bash
forge build --build-info
slither . --solc solc-0.8.25
```

## Fixed

| Detector | Where | What was wrong | Fix | Test |
|---|---|---|---|---|
| `unchecked-transfer` | `LendingPool.liquidate` | `asset.transferFrom(...)` was the only pull in the contract whose return value was not checked. An asset that answers `false` instead of reverting would let the liquidation seize collateral without the repayment arriving. | Wrapped in `require(..., "TRANSFER")`, matching the other three transfers | `test_liquidation_reverts_when_the_pull_reports_failure` |
| `events-access` | `TwapOracle.transferOwnership` | Owner changed with no event; ownership moves are exactly what an operator has to see in a log. | Added `OwnershipTransferred` and emit it before the assignment | `test_transfer_ownership_emits_event` |
| `missing-zero-check` | `TwapOracle` constructor | `feeder_ == address(0)` was accepted, producing an oracle nobody could push to until the owner noticed. | `require(feeder_ != address(0), "FEEDER")` | `test_zero_feeder_is_rejected` |
| `missing-zero-check` | `Timelock.execute` | `target == address(0)` made the low-level call succeed, so the timelock reported `Executed` for an action that did nothing. | `require(target != address(0), "TARGET")` | `test_execute_rejects_zero_target` |

All four rows are Low: none of them move funds on their own. They are recorded in
[`../AUDIT.md`](../AUDIT.md) as F-03 to F-05 with the same evidence.

## What remains, and why

| Detector | Hits | Verdict | Reason |
|---|---:|---|---|
| `timestamp` | 14 | by design | TWAP accumulation, feed staleness, the timelock delay and the accrual interval are time-based by construction. None of these decide value from a manipulable timestamp alone: `TwapOracle` also enforces `maxDeviation` against the feed and the sequencer-uptime check. |
| `incorrect-equality` | 6 | by design | All six compare against zero (`dt == 0`, `totalDebtShares == 0`, `debt == 0`) or test exact repayment (`repaid == debt`). Strict equality against zero is the intended control flow. |
| `reentrancy-no-eth` | 4 | accepted | `deposit`, `mint`, `liquidate` write state after `transferFrom`. Exploiting it needs a malicious asset or collateral token; both are immutable, fixed at deploy, with no setter and no upgrade path. |
| `reentrancy-benign` | 3 | accepted | Same pattern, no value at risk: the post-call writes are share minting and collateral accounting. |
| `reentrancy-events` | 1 | accepted | `Timelock.execute` emits after the call. The event is a record, not a control input. |
| `unused-return` | 2 | false positive | `TwapOracle._feedPrice` checks `answer > 0`, `updatedAt + maxAge >= block.timestamp` and `answeredInRound >= roundId`; the sequencer check verifies `status == 0` and the grace period. Every field the detector calls ignored is consumed on the next lines. |
| `low-level-calls` | 1 | by design | `Timelock.execute` exists to make an arbitrary call; the result is checked with `require(ok, "CALL_FAILED")`. |
| `immutable-states` | 1 | style | `LendingPool.model` is set once in the constructor and never changes; `immutable` would save a storage read per accrual. |

## Threat model this triage assumes

- The asset and collateral tokens are fixed at construction, are not upgradeable, and behave like
  ordinary ERC-20s (revert on failure). A fee-on-transfer or reentrant token breaks the accounting,
  which is why `LendingPool` is documented as a testbed rather than a drop-in pool.
- The oracle's feeder is a trusted keeper; the timelock owns both the pool and the oracle, and its
  owner is an EOA in the Sepolia deployment.
- The sequencer-uptime feed may be `address(0)`, in which case the check is skipped by design (L1
  deployments have no sequencer).

## Reproducing

```bash
cd 02-protocol-lab
forge build --build-info
slither . --solc solc-0.8.25          # 39 findings on the current tree
```

`slither.txt` can be diffed against a fresh run: the detector set and its order are stable for this
commit.
