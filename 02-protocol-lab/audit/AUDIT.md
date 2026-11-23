# Self-audit — LendingPool testbed

Scope: `src/LendingPool.sol`, `src/InterestModel.sol`, `src/TwapOracle.sol`, `src/Timelock.sol`,
`src/libraries/MathX.sol`. This is the author reviewing their own code; it is not an independent
audit, and the protocol is not production software.

## F-01 — Interest rate truncates to zero below the kink

**Severity:** High for the testbed's purpose (lenders earn nothing), self-found.
**Location:** `src/InterestModel.sol`, `apr()`.
**Status:** fixed; found by `test_interest_accrues_to_lenders`.

**Root cause.** The kinked curve was written as

```solidity
return baseRate + u.wadMul(slope1) / kink;
```

`u.wadMul(slope1)` is WAD-scaled, but dividing by `kink` (also WAD-scaled) without multiplying by
WAD first truncates the whole term to zero for any utilization below the kink. At 15% utilization
the model returned 0% APR, so `totalDebt` never grew.

**Impact.** Lenders receive no interest; `borrowIndex` stays at 1e18; borrowers repay exactly what
they borrowed. Silent: nothing reverts, and the pool looks healthy.

**Fix.**

```solidity
return baseRate + (u.wadMul(slope1) * WAD) / kink;
```

**How it was caught.** `test_interest_accrues_to_lenders` warps a year, calls `accrue()`, and
asserts `debtOf(borrower) > debtBefore`. Before the fix the assertion failed with two equal values.

**Residual risk.** The upper branch `((u - kink) * slope2) / (WAD - kink)` is correct because both
sides are WAD-scaled; a separate test at utilization above the kink should exist and does not yet.

## F-02 — Per-user debt and pool debt drift apart by rounding dust

**Severity:** Low (accounting dust, no value transfer), self-found by Echidna.
**Location:** `src/LendingPool.sol`, `borrow` / `repay` / `liquidate`.
**Status:** fixed by moving `totalDebt` to a shares basis.

**Root cause.** `totalDebt` was an independent accumulator, while each position's debt was
`debtShares * borrowIndex / 1e18` with shares rounded **up**. Every borrow and repay moved the two
figures by slightly different amounts, so `Σ debtOf(user)` could exceed `totalDebt`.

**Evidence.** The Echidna campaign found it in 3,040 calls:

```
echidna_debt_within_total: failed!
  totalDebt() -> 347177543134000
  debtOf(EchidnaProps) -> 347177543134001
```

After the first property relaxation it failed again by 2 wei, which showed the gap grows with the
number of operations rather than being a constant.

**Impact.** No funds move: the difference is bounded by one wei per position per operation and is
invisible at 18 decimals. It matters because `totalDebt` is part of `totalAssets`, so the share
price carried a rounding bias, and because an invariant that needs a fudge factor is not an
invariant.

**Fix.** Track `totalDebtShares` and derive `totalDebt() = totalDebtShares * borrowIndex / 1e18`,
exactly like the asset side. Borrow, repay and liquidation move shares in both places at once, so
`Σ debtOf ≤ totalDebt` holds by construction (floor is subadditive). The Echidna property is back
to `debtOf <= totalDebt` with no tolerance.

**Residual risk.** Interest accrual still floors at the position level, so the sum can be below the
total by a few wei in the pool's favour. That direction is safe and is not socialised.

## F-03 - The liquidation pull ignores its return value

**Severity:** Low. **Location:** `src/LendingPool.sol`, `liquidate()`.
**Found by:** Slither (`unchecked-transfer`) on the first static-analysis pass.
**Status:** fixed; `test_liquidation_reverts_when_the_pull_reports_failure`.

**Root cause.** Every transfer in the contract is wrapped in `require(..., "TRANSFER")` except the
one that pulls the repayment in `liquidate`: `asset.transferFrom(msg.sender, address(this), repaid);`.
With an ERC-20 that returns `false` instead of reverting, the liquidation continued: collateral was
seized, debt was burned, and the repayment never arrived.

**Impact.** Bounded by the position being liquidated, and unreachable with the deployed `MockERC20`
(which reverts on failure). It matters for the same reason the rest of the contract checks: the
assumption "the token reverts" is a property of the token, not of this code.

**Fix.** `require(asset.transferFrom(msg.sender, address(this), repaid), "TRANSFER");`

## F-04 - Ownership of the oracle can change with no event

**Severity:** Low. **Location:** `src/TwapOracle.sol`, `transferOwnership()`.
**Found by:** Slither (`events-access`).
**Status:** fixed; `test_transfer_ownership_emits_event`.

**Root cause.** `transferOwnership` assigned `owner` and emitted nothing, while `LendingPool` and
`Timelock` both emit on ownership change.

**Impact.** No funds move. The cost is operational: an ownership handover on the contract that prices
every loan leaves no trace to reconcile against. **Fix.** `event OwnershipTransferred(address indexed
previousOwner, address indexed newOwner)` emitted before the assignment.

## F-05 - Two addresses are accepted as zero

**Severity:** Low. **Location:** `src/TwapOracle.sol` (constructor), `src/Timelock.sol` (`execute`).
**Found by:** Slither (`missing-zero-check`).
**Status:** fixed; `test_zero_feeder_is_rejected`, `test_execute_rejects_zero_target`.

**Root cause.** The oracle accepts `feeder_ == address(0)`, which leaves it unpushable until the owner
notices and calls `setFeeder`; and `Timelock.execute` accepts `target == address(0)`, where the
low-level call succeeds and the timelock reports `Executed` for an action that did nothing - a silent
no-op in the one place that is supposed to be auditable.

**Impact.** Availability and observability, not funds. **Fix.** `require(feeder_ != address(0),
"FEEDER")` in the constructor and `require(target != address(0), "TARGET")` in `execute`.

## Known limitations (not findings)

| Item | Why it is accepted here |
|---|---|
| Virtual shares cost a few parts per billion of rounding | documented in `test_donation_does_not_steal_from_next_depositor`; cheaper than the inflation attack |
| Keeper can push any price | the TWAP is only as good as its feeder; the feed deviation check bounds a single bad push, not a sustained one |
| Single collateral, no debt ceiling | scope choice for the testbed |
| Liquidation bonus fixed at 5% | not tuned per asset |
| No pause / emergency shutdown | out of scope for the testbed |
| `withdraw` reverts when idle liquidity is insufficient | ERC-4626 allows this; a real market would queue withdrawals |

## Test gaps

- No fork test against a real pool; the oracle's Uniswap leg is a keeper push, not an on-chain
  accumulator.
- Echidna ran in WSL (20,000 calls, `test/echidna/RESULTS.md`) but is not part of CI.
- No invariant covering "share price never falls except on a bad-debt event"; the current suite
  checks accounting identities, not price monotonicity.
