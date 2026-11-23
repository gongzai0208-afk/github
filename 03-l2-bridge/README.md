# 03 — L2 and bridges

Cross-chain assumptions are where a single wrong line moves real value. This track reviews an
OP Stack deployment on two levels: the contracts, and the configuration they were deployed with.

Target: OP Sepolia (`11155420`) and its L1 contracts on Sepolia (`11155111`), read at L1 block
12,195,927 / L2 block 51,818,604. Full write-up in `AUDIT.md`.

## Status

| Piece | State |
|---|---|
| Alias helper + tests | done — `src/libraries/AddressAliasHelper.sol`, 5 tests |
| Checklist | done — `CHECKLIST.md`, 24 items, 13 closed by an assertion |
| Fork suite | done — `test/fork/`, 19 tests against the live deployment |
| Report | done — `AUDIT.md` |
| Target selection | done — OP Sepolia as reference; the same suite re-run on Unichain Sepolia, 19/19 |

**24 tests pass on OP Sepolia**: 5 offline, 13 wiring, 6 impersonation. The 19 fork tests also pass
against Unichain Sepolia (`FORKS.md`), which is what the env-driven `ForkBase` is for. No critical or
high severity issue; the report's value is the negative evidence and three observations, one of which
(O-1) is a governance address that is not a contract on either chain.

## Why two levels

Contract bugs in `L1StandardBridge` and `CrossDomainMessenger` are rare and heavily reviewed.
Deployment configuration is neither: a proxy admin held by an address with no code, a paused bridge
nobody remembers pausing, an implementation that does not match the verified source, a governance
address that differs from the documented one. Those are observable on-chain, need no new code, and
are exactly what an operator gets wrong.

## Layout

```
src/libraries/AddressAliasHelper.sol   L1→L2 alias, the most-misused primitive in OP Stack
src/interfaces/IOpStack.sol            the deployed surface this track reads, declared locally
test/AddressAliasHelper.t.sol          known vector, roundtrip fuzz, wraparound, undo trap
test/fork/ForkBase.sol                 two forks, env-driven target, EIP-1967 readers
test/fork/Wiring.t.sol                 13 wiring assertions (A1, A2, A4, B1, D1, E1, E3, F2–F4)
test/fork/MessengerImpersonation.t.sol 6 tests on the alias boundary, including the PoC
test/mocks/MintableToken.sol           bridge-gated mint, used to exercise the ERC20 path
CHECKLIST.md                           24 checks, results filled
AUDIT.md                               the report: what holds, the boundary, O-1..O-3, gaps
FORKS.md                               run of record, env vars, commands, reuse on another chain
```

## Verify

```bash
# offline only
forge test --no-match-path "test/fork/*"

# against the live deployment (needs an L1 and an L2 endpoint)
forge test --match-path "test/fork/*" -vv
```

If the sandbox cannot write foundry's global solc cache, point it at a local binary:
`forge test --use /path/to/solc-0.8.25`. `FORKS.md` has the env vars for pinning a block and for
running the same suite against Unichain Sepolia.

## The one boundary worth reading

`L2CrossDomainMessenger._isOtherMessenger()` is `undoL1ToL2Alias(msg.sender) == otherMessenger` — an
address predicate. Everything the L2 side trusts about L1, including the value `xDomainMessageSender()`
returns to the bridge, rests on nobody being able to transact from `alias(L1CrossDomainMessenger)`.

`test_POC_alias_bypass_is_accepted_as_cross_domain` and
`test_POC_finalizeBridgeERC20_mints_unbacked_supply` show what that would mean if it failed;
`test_C1_aliased_l1_messenger_has_no_code_on_l2` shows why it does not. The mint PoC deploys its own
token, so it proves the authorisation rather than a profit — `AUDIT.md` §4 says so.

## What this track does not claim

- No critical or high severity finding on the standard bridge, and none is implied.
- O-1 must be confirmed with the operator before anyone calls it a vulnerability; it may be an
  intentional testnet governance address.
- Six checklist items are open and listed in `AUDIT.md` §4; the report does not launder them as
  "reviewed".
