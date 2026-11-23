# 01 — Bytecode lab

Reviewing a contract when no source is published. The tooling is the deliverable: decode the runtime
bytecode, recover the dispatcher, turn each selector into a row an auditor can reason about, and keep
every claim traceable to an offset.

## What is here

| Module | Does | Verified by |
|---|---|---|
| `evmlab/disasm.py` | linear sweep, PUSH-immediate aware, strips the solc CBOR trailer, opcode histogram | `TestDisasm` (6 cases) |
| `evmlab/selectors.py` | recovers 4-byte selectors from solc `PUSH4 … EQ … JUMPI` and Vyper-style dispatch | `TestSelectors` (4 cases) |
| `evmlab/entries.py` | selector → jump target, body size, guard signals, storage/call/log counts | `TestEntries` (2 cases) |
| `evmlab/report.py` | one contract or a directory to JSON + Markdown, with sha256 and both selector populations | `TestSample` |
| `evmlab/cli.py` | `disasm`, `selectors`, `entries`, `report`, `scan` | — |

It accepts raw `.bin` or hex text (`cast code` output, `0x…`), so a sample can live in the repository
as readable text and still be fed to every command.

## Run it

```bash
cd 01-bytecode-lab
PYTHONPATH=. python -m evmlab report samples/Dispatcher.bin
PYTHONPATH=. python -m evmlab entries samples/Dispatcher.bin
PYTHONPATH=. python -m unittest discover -s tests -v     # 14 tests, no dependencies
```

On `samples/` (615 bytes of runtime, compiled from `samples/Dispatcher.sol`):

```
selectors   6
entries     0x55241077  setValue(uint256)  caller guard, sstore
            0xff9913e8  allow(address)     caller guard, sstore, 5 revert sites
            0x18178358  poke()            unguarded, read-modify-write
```

The entry table is the product: for each selector, what the function touches and whether it checks
`msg.sender`. `samples/README.md` lists what the table should say, so a wrong result is visible.

## Case study (not redistributed)

One engagement covered 14 proxy shells with 11 EIP-1967 implementations and 373 distinct selectors,
five contracts of which had no coverage in the published review. The aggregate numbers are quoted
here; the binaries are third-party code and are not in this repository.

Work product per contract: entry point, storage reads and writes, external calls, and one conclusion
per entry — `observed`, `refuted`, or `not reached`. Only `observed` becomes a finding, and only with
a state assertion that fails against a patch.

## Limits

- No control-flow graph and no storage-layout recovery. The README of an earlier draft listed both;
  they are not implemented, and this file says so.
- The body walk stops at the next jump target, so the storage counts are a **lower bound**, not a
  complete tally.
- Selector recovery sees the `EQ` guard shape only. Jump-table dispatch and hand-written assembly
  dispatchers are missed, and `scan` reports both selector counts so the gap is visible
  (`push4_constants` vs `eq-guarded`).
- No decompiler. Nothing here produces compilable Solidity, and no report claims it does.

## Non-goals

- A finding without a runnable state assertion.
- A "reconstructed" patch presented as the project's fix.
