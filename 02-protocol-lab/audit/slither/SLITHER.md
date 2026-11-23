# Static analysis — what Slither reported, and what was done with it

**Tool:** slither 0.11.6, 102 detectors.
**Scope:** `src/` — 8 contracts, 750 lines. `test/`, `script/` and the mocks are excluded.
**Result:** 43 findings across 11 detectors. Raw output: [`slither.txt`](slither.txt).

```bash
forge build --build-info
slither . --solc solc-0.8.25
```

## Disposition

| Detector | Hits | Verdict | Why |
|---|---:|---|---|
| `timestamp` | 14 | by design | TWAP accumulation, feed staleness, the timelock's delay and the interest accrual interval are all time-based. The detector fires on every comparison; none of these decide value from a manipulable timestamp alone — `TwapOracle` also enforces `maxDeviation` against the feed and the sequencer-uptime check. |
| `incorrect-equality` | 6 | by design | All six compare against zero (`dt == 0`, `totalDebtShares == 0`, `debt == 0`) or test exact repayment (`repaid == debt`). Strict equality against zero is the intended control flow here. |
| `reentrancy-no-eth` | 4 | accepted | `deposit`, `mint`, `liquidate` write state after `transferFrom`. Exploiting it requires a malicious asset or collateral token; both are immutable and fixed at deploy, with no setter and no upgrade path (`LendingPool` has no owner-controlled token change). Documented in the threat model below. |
| `reentrancy-benign` | 3 | accepted | Same pattern, no value at risk: the post-call writes are share minting and collateral accounting. |
| `reentrancy-events` | 1 | accepted | `Timelock.execute` emits after the call. The event is a record, not a control input. |
| `unused-return` | 2 | false positive | `TwapOracle._feedPrice` checks `answer > 0`, `updatedAt + maxAge >= block.timestamp` **and** `answeredInRound >= roundId`; the sequencer check verifies `status == 0` and the grace period. Every field the detector calls ignored is consumed on the next lines. |
| `unchecked-transfer` | 1 | **real, Low** | `LendingPool.liquidate` calls `asset.transferFrom(msg.sender, address(this), repaid)` without checking the return value while every other transfer in the contract is wrapped in `require(..., "TRANSFER")`. With an asset that returns `false` instead of reverting, a liquidation would seize collateral without receiving the repayment. The deployed asset is a `MockERC20` that reverts, so it is not reachable in the testbed; the fix is one line and is listed as a follow-up rather than silently patched. |
| `events-access` | 1 | **real, Low** | `TwapOracle.transferOwnership` changes `owner` and emits nothing. Ownership moves are the ones an operator needs to see in a log; `LendingPool` and `Timelock` both emit. |
| `missing-zero-check` | 2 | **real, Low** | `TwapOracle` accepts `feeder_ == address(0)` (recoverable: `setFeeder` exists and is owner-only), and `Timelock.execute` accepts `target == address(0)`, where the low-level call succeeds and the timelock reports `Executed` for an action that did nothing. |
| `low-level-calls` | 1 | by design | `Timelock.execute` exists to make an arbitrary call; the result is checked with `require(ok, "CALL_FAILED")`. |
| `immutable-states` | 1 | style | `LendingPool.model` is set once in the constructor and never changes; declaring it `immutable` would save a storage read per accrual. |

## What this report is used for

Three of the eleven detectors point at something worth a patch, and all three are Low: an unchecked
`transferFrom` in the liquidation path, a silent ownership change in the oracle, and two missing
zero-address checks. None of them move funds on their own. The rest is either the shape of the code
(timestamp comparisons in a TWAP, arbitrary calls in a timelock) or a detector heuristic that cannot
see the surrounding `require`s.

## Threat model this triage assumes

- The asset and collateral tokens are fixed at construction, are not upgradeable, and behave like
  ordinary ERC-20s (revert on failure). A fee-on-transfer or reentrant token breaks the accounting,
  which is why `LendingPool` is documented as a testbed and not as a drop-in pool.
- The oracle's feeder is a trusted keeper; the timelock owns both the pool and the oracle, and its
  owner is an EOA in the Sepolia deployment.
- The sequencer-uptime feed may be `address(0)`, in which case the check is skipped by design (L1
  deployments have no sequencer).

## Reproducing

```bash
cd 02-protocol-lab
forge build --build-info
slither . --solc solc-0.8.25          # 43 findings
```

The counts are stable for this commit: slither walks the same detector set in the same order, so the
`slither.txt` in this folder can be diffed against a fresh run.
