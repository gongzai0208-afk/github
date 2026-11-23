# Audits

Three Solidity reviews, each with the report in English and Chinese, the reviewed sources, runnable Foundry
proofs of concept, one patch tree per finding, a merged patch tree, and the raw test output for every
run. The claim this set supports is the **verification chain**: a reader can re-run it without
trusting the author.

| Review | Scope | Findings | Report |
|---|---|---|---|
| [2024-07-traitforge](2024-07-traitforge/) | 6 contracts · 880 nSLOC · commit `279b2887` | 2 High · 6 Medium · 3 Low | [EN](2024-07-traitforge/README.md) · [中文](2024-07-traitforge/README.zh.md) |
| [staking-rewards](staking-rewards/) | 1 contract · 159 LoC | 1 High · 1 Medium · 1 Low | [EN](staking-rewards/README.md) · [中文](staking-rewards/README.zh.md) |
| [naive-receiver](naive-receiver/) | 4 contracts · 254 LoC | 2 High | [EN](naive-receiver/README.md) · [中文](naive-receiver/README.zh.md) |

16 findings, 17 PoC tests, 16 per-finding patch trees, 3 merged trees, 3 regression suites, 3
invariant suites (64 runs × 32 depth).

**Provenance, stated per review.** TraitForge is a public Code4rena contest (2024-07) and
NaiveReceiver is a public Damn Vulnerable DeFi challenge — both are reproductions against published
answers, not claims of independent discovery, and each report says so in its limitations section.
StakingRewards is a small open-source repository with no published findings: found from the contract
alone, and the one with no external confirmation.

## Findings by vulnerability class

| Class | Findings | The shape of the bug |
|---|---|---|
| Missing bound / off-by-one | TF F-01, TF F-06 | A counter is compared against the wrong limit, or incremented one step too far |
| State reset and read-order | TF F-02, TF F-03, TF F-04 | A generation counter is zeroed while another function may already have written to it; a price is read one step before the state it depends on changes |
| Accounting identity | SR F-01, SR F-02, TF F-05, TF F-07 | The contract's bookkeeping disagrees with the tokens it holds, or debits the wrong party |
| Authorisation and identity | NR F-01, NR F-02, TF F-10 | A call acts for someone who never authorised it; a cross-contract permission model is mutually exclusive |
| Dead safety mechanism | TF F-08, TF F-09 | A pause switch that cannot be reached; a treasury address that can be set to zero |
| Unit and scale | TF F-11 | One value is used with two different units (`taxCut` as a percent in the comment, a divisor in the code) |
| Availability and revert semantics | SR F-03 | A function reverts where it should be a no-op |

`TF` = 2024-07-traitforge, `SR` = staking-rewards, `NR` = naive-receiver.

## The chain, and where each link lives

| Step | What it proves | Files |
|---|---|---|
| 1. Freeze | The review is pinned: commit, per-file blob SHA-1, line counts, compiler, dependency versions | §2 of each `README.md`, `logs/versions.txt` |
| 2. PoC asserts observable state | A balance, a counter or an emitted value changes — not merely "the call did not revert" | `<audit>/test/*.t.sol` |
| 3. Per-finding patch, PoC must fail | The test actually bites on that change | `<audit>/fixes/F-xx/` + `NOTES.md`, `logs/fixfail-*.txt` |
| 4. Merged patch, PoCs still fail | The fixes coexist, and the suite runs against what a project would ship | `<audit>/fixes/ALL/`, `logs/all-poc-fail.txt` |
| 5. Regression | The fixes did not break normal flows | `<audit>/test/Regression.t.sol`, `logs/regression-all.txt` |
| 6. Invariants | Conservations hold on both the reviewed and the patched build | `<audit>/test/invariant/`, `logs/baseline.txt` |

Step 4 is not ceremony: merging the TraitForge patches exposed an interaction bug that no single
patch showed — a batch mint rolled back entirely at the last generation, because one fix bounded the
generation counter and another moved the price read. It is written up in that report and fixed by
ordering the settle after the final generation is reached.

## Run it

```bash
cd 2024-07-traitforge
forge install foundry-rs/forge-std            # if lib/ was not carried over
forge test -vv                                # baseline: 16 pass, 6 skipped

# every PoC against its own patch: each must now fail
forge test --remappings 'traitforge/=fixes/F-01/src/' --match-test test_PoC_P4

# all fixes merged: PoCs fail, normal flows must still pass
forge test --remappings 'traitforge/=fixes/ALL/src/' --match-path test/Regression.t.sol
```

Each folder vendors its own sources and dependencies, so it builds without cloning anything else.

## Severity ruler

One set of definitions, printed identically in all three reports:

- **High** — loss of user funds or a broken core invariant, reachable through the documented flow
  with well-formed input, without the victim supplying a wrong amount and without a privileged role
  setting an invalid value.
- **Medium** — bounded or self-inflicted value loss, economic distortion, or denial of service under
  normal use.
- **Low** — requires a privileged role to set an invalid value first, a dead safety mechanism, or no
  direct fund loss.

A privileged call still counts as the documented flow when the contract itself validates that input;
a wrong value is excluded from High only where the code performs no check on it. Where a rating
differs from the project's published findings, the report says so and gives the reason.

## Limits

- Reviews are point-in-time assessments of one commit. They are not a guarantee that the codebase is
  free of other issues.
- TraitForge and NaiveReceiver have public answer keys; they demonstrate the method and the
  verification chain, not recall on unseen code.
- StakingRewards has no published findings and no external confirmation.
- PoCs written against pinned commits and blocks may not reproduce after those projects change.
