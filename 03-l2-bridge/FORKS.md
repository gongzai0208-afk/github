# Fork runs

Every assertion in `test/fork/` executes against a live endpoint. This file records how to reproduce
a run and what a specific run saw, so the report can be checked without trusting it.

## Run of record

| Field | Value |
|---|---|
| Date | 2026-11-23 |
| Target | OP Sepolia (`chainId 11155420`), L1 Sepolia (`chainId 11155111`) |
| L1 block | 12,195,927 |
| L2 block | 51,818,604 |
| Result | 24 tests passed, 0 failed (5 alias + 13 wiring + 6 impersonation) |

## Components read at that block

| Component | Address | `version()` |
|---|---|---|
| L1StandardBridge (proxy) | `0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1` | 2.8.2 |
| L1CrossDomainMessenger (legacy proxy) | `0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef` | 2.13.0 |
| OptimismPortal2 (proxy) | `0x16Fc5058F25648194471939df75CF27A2fdC48BC` | 6.1.0 |
| SystemConfig (proxy) | `0x034edD2A225f7f429A63E0f1D2084B9E0A93b538` | 4.3.0 |
| DisputeGameFactory (proxy) | `0x05F9613aDB30026FFd634f38e5C4dFd30a197Fa1` | — |
| SuperchainConfig | `0xC2Be75506d5724086DEB7245bd260Cc9753911Be` | — |
| L2StandardBridge | `0x4200000000000000000000000000000000000010` | 1.13.2 |
| L2CrossDomainMessenger | `0x4200000000000000000000000000000000000007` | 2.2.1 |

## Commands

```bash
# point it at a local solc binary when the global cache is not writable
forge test --use /path/to/solc-0.8.25 \
  --match-path "test/fork/*" -vv

# pin the run so a later reader sees the same state
OP_L1_BLOCK=12195927 OP_L2_BLOCK=51818604 forge test --match-path "test/fork/*"
```

Offline tests need no endpoint:

```bash
forge test --no-match-path "test/fork/*"
```

## Env vars

| Variable | Default | Meaning |
|---|---|---|
| `OP_L1_RPC` | `https://ethereum-sepolia-rpc.publicnode.com` | L1 endpoint |
| `OP_L2_RPC` | `https://sepolia.optimism.io` | L2 endpoint |
| `OP_L1_BLOCK` / `OP_L2_BLOCK` | `0` = latest | pin the fork |
| `OP_L1_BRIDGE` | OP Sepolia bridge | L1 bridge proxy |
| `OP_PORTAL` | OP Sepolia portal | L1 portal proxy |
| `OP_SYSTEM_CONFIG` | OP Sepolia SystemConfig | L1 SystemConfig proxy |
| `OP_DGF` | OP Sepolia DisputeGameFactory | L1 DGF proxy |
| `OP_PROXY_ADMIN_OWNER` | `0x1Eb2…F56E2` | governance owner from the superchain registry |
| `OP_PROOF_MATURITY` | `604800` | expected `proofMaturityDelaySeconds` |
| `OP_GAME_FINALITY` | `302400` | expected `disputeGameFinalityDelaySeconds` |
| `OP_L1_TOKEN` / `OP_L2_TOKEN` | Sepolia WETH / L2 WETH predeploy | pair checked for decimals |

## Why the default is "latest" and not a pinned block

Public L1 endpoints prune state; a fork pinned weeks back fails with a state-lookup error that looks
like a broken test. The run of record is pinned above, and `FORKS.md` is updated with each review.

## Second run — Unichain Sepolia

| Field | Value |
|---|---|
| Date | 2026-11-23 |
| Target | Unichain Sepolia (`chainId 1301`) |
| L1 block | 12,195,937 |
| L2 block | 68,587,446 |
| L1 messenger | `0x448A37330A60494E666F6DD60aD48d930AEbA381` |
| Result | 19 tests passed, 0 failed |

Every check that held on OP Sepolia also held here: same pairing, same 7 day / 3.5 day delays, same
unpaused state, WETH decimals equal, and the L1 messenger is again a legacy resolved proxy rather
than an EIP-1967 proxy. The L2 ProxyAdmin owner is the same address as on OP Sepolia
(`0x2FC3…67F3`), which is why O-1 is written as an observation to confirm rather than a finding.

## Reusing this on another chain

Only the L1 system addresses and the L2 endpoint change; the L2 predeploys are the same everywhere.

```bash
# Unichain Sepolia (1301)
OP_L2_RPC=https://sepolia.unichain.org \
OP_L1_BRIDGE=0xea58fcA6849d79EAd1f26608855c2D6407d54Ce2 \
OP_PORTAL=0x0d83dab629f0e0F9d36c0Cbc89B69a489f0751bD \
OP_SYSTEM_CONFIG=0xaeE94b9aB7752D3F7704bDE212c0C6A0b701571D \
OP_DGF=0xeff73e5aa3B9AEC32c659Aa3E00444d20a84394b \
forge test --match-path "test/fork/*"
```

Some checks are chain-specific by nature: `test_E3` (legacy proxy) only holds where the L1 messenger
has not been migrated to an EIP-1967 proxy, and the default delay constants assume the standard
7 day / 3.5 day configuration.
