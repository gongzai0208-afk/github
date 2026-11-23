# Smart-contract security — field work

Three labs, each written to answer a question that a review alone cannot:

| Lab | Question | Evidence |
|---|---|---|
| [01-bytecode-lab](01-bytecode-lab/) | Can I audit a contract with no source? | disassembler + dispatcher recovery, 14 tests, sample entry table |
| [02-protocol-lab](02-protocol-lab/) | Can I build the DeFi primitives I review? | ERC-4626 pool + oracle + timelock, 36 tests, 5 invariants, Echidna, live on Sepolia, source verified |
| [03-l2-bridge](03-l2-bridge/) | Do I understand L2 and cross-chain assumptions? | 24 tests against OP Sepolia and Unichain Sepolia, 24-item checklist, one written report |

Every claim has a command behind it. Where a lab did not finish a piece, its README says which piece.

## Verify

```bash
# 01 — no dependencies beyond python
cd 01-bytecode-lab && PYTHONPATH=. python -m unittest discover -s tests -v

# 02 — needs foundry; `forge install foundry-rs/forge-std` once
cd 02-protocol-lab && forge test

# 03 — offline half; the fork half needs an RPC (see 03-l2-bridge/FORKS.md)
cd 03-l2-bridge && forge test --no-match-path 'test/fork/*'
cd 03-l2-bridge && forge test --match-path 'test/fork/*'
```

CI runs the offline halves on every push (`.github/workflows/ci.yml`).

## What is verifiable without trusting me

- **02** is deployed on Sepolia and verified on Etherscan: seven addresses, transaction hashes and
  the on-chain state check in [deployments.md](02-protocol-lab/deployments.md). The self-audit that
  found two bugs is in [AUDIT.md](02-protocol-lab/audit/AUDIT.md), including the one Echidna found
  that a unit test missed.
- **03** is a review of a live deployment, pinned by block number in
  [FORKS.md](03-l2-bridge/FORKS.md); the report states which 24 checklist items are closed by an
  assertion and which six are explicitly open.
- **01** ships the bytecode it analyses, so the 14 tests can be re-run and the table re-derived.

## Limits, stated up front

- `02` is a testbed. Mock tokens, a mock feed, a 60-second TWAP window, one EOA in control. It has
  not been audited by a third party and is not production configuration.
- `03` found no critical or high severity issue, and does not imply one. Its most interesting output
  is a governance address that differs from the registry's — reported as an observation to confirm,
  not as a vulnerability.
- `01` works on single contracts. It has no CFG, no storage-layout recovery and no decompiler.
- Nothing here is a claim about code I have not seen.

## Licence

Code: MIT ([LICENSE](LICENSE)). Reports and prose: CC-BY-4.0.
