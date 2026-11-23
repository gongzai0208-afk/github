# Echidna campaign — results

**Tool:** Echidna 2.4.0 (x86_64-linux)
**Compiler:** solc 0.8.25 (Foundry's svm)
**Compiler driver:** crytic-compile 0.4.2 (`pipx install crytic-compile`)
**Host:** WSL2 Ubuntu, project checked out at `~/work/02-protocol-lab`

## Command

```bash
cd ~/work/02-protocol-lab
echidna test/echidna/EchidnaProps.sol --contract EchidnaProps \
  --config echidna.yaml --test-limit 20000 --seq-len 50
```

## Result (after the fix described below)

```
echidna_collateral_backed: passing
echidna_total_assets_match: passing
echidna_debt_within_total: passing

Unique instructions: 6796
Unique codehashes: 10
Corpus size: 13
Total calls: 20000
```

Four workers, ~20k calls in ~4 seconds of fuzzing after compilation.

## What it found

The first campaign failed `echidna_debt_within_total` by one wei:

```
totalDebt()          -> 347177543134000
debtOf(EchidnaProps) -> 347177543134001
```

After a one-wei tolerance it failed again by two, which showed the gap grows with the number of
operations. Root cause and fix are recorded as **F-02** in `audit/AUDIT.md`: `totalDebt` was an
independent accumulator while per-user debt was share-derived and rounded up. The pool now tracks
`totalDebtShares` and derives `totalDebt()`, so the property holds with no tolerance.

This is the useful outcome of a campaign: it did not find a theft, it found that an invariant was
not actually an invariant.

## What this campaign does not cover

- **One actor.** `EchidnaProps` is a single address; multi-actor composition is covered by
  `test/invariant/` (3 actors, 64 runs × 32 depth).
- **No price movement.** The harness uses `FixedOracle`, so liquidation is unreachable here; that
  path is covered by unit tests and the Foundry handler.
- **No time-based interest path.** Echidna can advance time, but the properties do not assert on
  accrued interest.

## Reproduce on Linux/WSL

```bash
pipx install crytic-compile
# download echidna 2.4.0 x86_64-linux from the crytic/echidna releases page
echidna test/echidna/EchidnaProps.sol --contract EchidnaProps --config echidna.yaml
```

On native Windows the binary starts but cannot spawn `crytic-compile` reliably (non-UTF-8 child
output; `solc-select` writing outside the writable area). WSL is the supported path here.
