# 02 — Protocol lab

A small DeFi protocol built from scratch, then audited by its author. The point is not another
demo: it is to show that the same evidence chain used on other people's code (finding → PoC →
patch → failed PoC → regression) also runs on code I wrote.

## Status

| Piece | State |
|---|---|
| Contracts | 5 in `src/`: pool (ERC-4626 + borrow), interest model, TWAP oracle, timelock |
| Unit tests | 40 passing, one `.t.sol` per contract |
| Invariant tests | 5 properties, 64 runs × 32 depth, passing |
| Echidna | 3 properties, 20,000 calls, passing in WSL — see `test/echidna/RESULTS.md` |
| Self-audit | `audit/AUDIT.md`: five bugs found (a unit test, Echidna, and three from static analysis) and fixed |
| Static analysis | `audit/slither/SLITHER.md`: 43 findings, 4 fixed, 39 remain by design (before/after reports kept) |
| Sepolia deployment | **live** — addresses, txs and on-chain checks in `deployments.md` |
| Source verified | **yes** — 7/7 on Sepolia Etherscan, see `deployments.md` |

Test files map to contracts one-to-one: `LendingPool.t.sol`, `InterestModel.t.sol`,
`TwapOracle.t.sol`, `Timelock.t.sol`, plus `EchidnaProps.t.sol` (harness deployability) and
`invariant/` (multi-actor handler).

## Contracts

| Contract | Responsibility | Hazard it must survive |
|---|---|---|
| `LendingPool` | ERC-4626 shares + isolated borrow/liquidate | first-depositor inflation, bad-debt allocation |
| `InterestModel` | kinked linear rate | integer-division truncation at low utilization |
| `TwapOracle` | keeper-pushed TWAP + Chainlink cross-check + L2 sequencer uptime | stale feed, single-block manipulation, sequencer downtime |
| `Timelock` | delayed execution; owns the pool | instant parameter changes |
| `MathX` | fixed-point helpers | rounding direction |

## What is deliberately not here

- Multiple collateral assets and per-asset risk parameters — one market is enough to show the
  accounting, and more surface would not be tested properly.
- A debt ceiling, pause switch, or emergency shutdown — these are risk controls, not core logic.
- Upgradeability — the pool is immutable; the timelock only changes parameters.

## Verify

```bash
forge test                     # 40 tests: unit + invariant
forge coverage --report summary
```

The deployment script reads `PRIVATE_KEY` from the environment and deploys mock tokens plus the
real oracle on Sepolia:

```bash
forge script script/DeployTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

Source verification (constructors rebuilt from the deployment script, key read from
`$env:ETHERSCAN_API_KEY` or a gitignored `.env`):

```bash
python scripts/verify_sepolia.py        # --cast/--solc if they are not on PATH
python scripts/verify_sepolia.py --status
```

Status: verified 7/7 — see `deployments.md`.

## Running Echidna

The campaign runs in WSL (Ubuntu, Echidna 2.4.0 + crytic-compile via pipx). On native Windows the binary starts but cannot spawn `crytic-compile` reliably (non-UTF-8
child output; `solc-select` writing outside the writable area), so WSL is the supported path.

```bash
echidna test/echidna/EchidnaProps.sol --contract EchidnaProps --config echidna.yaml
```
