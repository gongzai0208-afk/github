# Smart-contract security — audits and field work

Three reviews with runnable proof-of-concept tests, and three labs that answer questions a review
alone cannot. Everything here has a command behind it.

## Audits

| Review | Scope | Findings | Chain |
|---|---|---|---|
| [TraitForge NFT](audits/2024-07-traitforge/) | 6 contracts · 880 nSLOC | 2 High · 6 Medium · 3 Low | 11 patch trees + merged + regression |
| [StakingRewards](audits/staking-rewards/) | 1 contract · 159 LoC | 1 High · 1 Medium · 1 Low | 3 patch trees + merged + regression |
| [NaiveReceiver](audits/naive-receiver/) | 4 contracts · 254 LoC | 2 High | 2 patch trees + merged + regression |

**16 findings, 17 PoC tests.** Each PoC asserts an observable state change, each fails against its own
patch, all still fail against the merged patch, and a regression suite keeps the normal flows working.
The full index — findings by vulnerability class, and which file holds each link of the chain — is in
[`audits/README.md`](audits/README.md), along with the per-review provenance (two of the three are
public challenges with published answers and are labelled as reproductions, not discoveries).

## Labs

| Lab | Question | Evidence |
|---|---|---|
| [01-bytecode-lab](01-bytecode-lab/) | Can I audit a contract with no source? | disassembler + dispatcher recovery + entry table, 14 tests, one committed sample |
| [02-protocol-lab](02-protocol-lab/) | Can I build the DeFi primitives I review? | ERC-4626 lending pool + TWAP oracle + timelock, 36 tests, 5 invariants, Echidna campaign, source-verified on Sepolia, Slither triage |
| [03-l2-bridge](03-l2-bridge/) | Do I understand L2 and cross-chain assumptions? | 24 tests against OP Sepolia and Unichain Sepolia, 24-item checklist, written report |

`02` is deployed and its seven contracts are verified on Etherscan — addresses, transaction hashes and
an on-chain state check are in [deployments.md](02-protocol-lab/deployments.md). Its self-audit, with
two bugs found (one by a unit test, one by Echidna) and the fix for each, is in
[audit/AUDIT.md](02-protocol-lab/audit/AUDIT.md); the static-analysis pass and what was done with its
43 findings is in [audit/slither/SLITHER.md](02-protocol-lab/audit/slither/SLITHER.md).

## Verify

```bash
# audits — Foundry; each folder vendors its sources and dependencies
cd audits/2024-07-traitforge && forge test -vv
cd audits/staking-rewards    && forge test -vv
cd audits/naive-receiver     && forge test -vv

# 01 — python, no dependencies
cd 01-bytecode-lab && PYTHONPATH=. python -m unittest discover -s tests -v

# 02 — `forge install foundry-rs/forge-std` once
cd 02-protocol-lab && forge test

# 03 — offline half; the fork half needs an RPC, see 03-l2-bridge/FORKS.md
cd 03-l2-bridge && forge test --no-match-path 'test/fork/*'
```

CI runs the offline halves on every push (`.github/workflows/ci.yml`).

## Limits, stated up front

- Two of the three audits are reproductions of public challenges. They demonstrate method and
  verifiability, not recall on unseen code. StakingRewards has no public answer key and no external
  confirmation either.
- `02` is a testbed: mock tokens, a mock feed, a 60-second TWAP window, one EOA in control. It has not
  been audited by a third party and is not production configuration.
- `03` found no critical or high severity issue and does not imply one. Its most interesting output is
  a governance address that differs from the registry's — reported as an observation to confirm.
- `01` works on single contracts: no CFG, no storage-layout recovery, no decompiler.
- Nothing here is a claim about code I have not seen.

## Licence

Code: MIT ([LICENSE](LICENSE)). Reports and prose: CC-BY-4.0.
