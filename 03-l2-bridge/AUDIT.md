# OP Sepolia bridge review

Target: OP Stack deployment on OP Sepolia (`11155420`) with its L1 contracts on Sepolia (`11155111`).
Method: read the live deployment through fork tests and compare it against the contracts it claims to
be running. No source was taken on trust; every claim below points at a test or a byte offset.

Reviewed at L1 block 12,195,927 / L2 block 51,818,604. Reproduce with `FORKS.md`. The same suite was
also run against Unichain Sepolia (19/19), where every shared check gave the same result; any claim
below that is chain-specific says so.

## Summary

| | Count |
|---|---|
| Checklist items verified with an executable assertion | 13 |
| Verified by reading the deployed source path only | 2 |
| Observations worth a follow-up | 3 |
| Not covered in this pass | 6 |

No critical or high severity issue was found. That is the expected result for the standard bridge —
it is among the most reviewed code in the ecosystem. The value of this pass is the negative evidence:
what was checked, and the one boundary the whole L2 side rests on.

## 1. What holds

**Message pairing.** The L1 bridge trusts `0x58Cc…b3ef`, that messenger points back at
`0x4200…0007`, the L2 bridge trusts `0x4200…0007`, and that messenger points back at `0x58Cc…b3ef`.
The bridges' `otherBridge` values agree with the same pair. A one-sided upgrade would break this in a
way that is visible here before it is visible in an incident.
`test_A1_messengers_are_paired`, `test_A1_l1_bridge_uses_the_messenger_that_points_back`.

**Message identity.** The nonce carries `MESSAGE_VERSION = 1` in its top 16 bits on both sides, so
both ends agree on the encoding. `relayMessage` hashes `(nonce, sender, target, value, minGasLimit,
message)` and rejects a second relay of the same hash.
`test_A2_nonce_carries_the_message_version`.

**Sender is not ambient.** `xDomainMessageSender()` reverts when no relay is in flight, and the
portal's `l2Sender` sits at the `0xdEaD` sentinel outside a withdrawal. A target cannot mistake
"no message" for "from address(0)".
`test_A4_xDomainMessageSender_reverts_when_idle`.

**Finalisation is gated twice.** `StandardBridge.onlyOtherBridge` requires
`msg.sender == messenger && messenger.xDomainMessageSender() == otherBridge`. A direct call from an
EOA is rejected on both chains, and so is a call from the messenger with any other recorded sender.
`test_A3_bridges_reject_direct_callers`.

**Replay.** After a relay the same message hash cannot be relayed again; the second attempt reverts
with `message has already been relayed`. Reentrancy during the external call is caught separately:
`xDomainMsgSender` is non-sentinel, so the message is marked failed rather than executed twice.
`test_POC_alias_bypass_is_accepted_as_cross_domain` (second half).

**Withdrawal timing.** `proofMaturityDelaySeconds = 604800` (7 days) and
`disputeGameFinalityDelaySeconds = 302400` (3.5 days), the standard configuration.
`test_B1_withdrawal_delays_are_configured`.

**Governance.** The L1 ProxyAdmin is a contract (6,524 bytes) owned by the registry's
`ProxyAdminOwner` (`0x1Eb2…F56E2`, a 171-byte contract on L1), and the bridge, portal and messenger
all sit behind implementations. `test_E1_l1_governance_is_a_contract`.

**Pause state.** Bridge, both messengers, portal and SuperchainConfig all report not paused.
`test_F2_nothing_is_paused`.

**Portal wiring.** `systemConfig`, `disputeGameFactory` and `superchainConfig` match the registry;
the guardian is set; `respectedGameType = 9` has an implementation and 90,367 games exist.
`test_F3_portal_wiring_matches_the_registry`, `test_F4_respected_game_type_has_an_implementation`.

**Decimals.** L1 WETH and the L2 WETH predeploy both report 18 and the symbol matches.
`test_D1_bridged_token_decimals_match`.

**ETH failure is not swallowed.** `finalizeBridgeETH` requires the `SafeCall` to succeed and reverts
with `ETH transfer failed` otherwise. Read from the deployed source path, not exercised.
`StandardBridge.sol`, `finalizeBridgeETH`.

## 2. The boundary the L2 side rests on

`L2CrossDomainMessenger._isOtherMessenger()` is:

```solidity
return AddressAliasHelper.undoL1ToL2Alias(msg.sender) == address(otherMessenger);
```

That is an address predicate, not an identity check. If anything can transact from
`applyL1ToL2Alias(L1CrossDomainMessenger)`, it can call `relayMessage` with any `_sender`, and every
L2 contract that trusts `xDomainMessageSender()` — the standard bridge included — will believe it.

The tests prove both halves.

*If it were controllable:* pranked as `0x69DD85B8d04eA49CC6dbd3cBfFd00b4B8D6cC500`
(`alias(0x58Cc…b3ef)`), a hand-built `relayMessage` is accepted as a genuine L1→L2 message. With
`_sender = L1StandardBridge`, `L2StandardBridge.finalizeBridgeERC20` mints to the attacker — the
bridge keeps no token registry and trusts the `_localToken` argument, so any listed mintable token
would have its supply forged. `test_POC_alias_bypass_is_accepted_as_cross_domain`,
`test_POC_finalizeBridgeERC20_mints_unbacked_supply`.

*Why it does not apply:* the alias address holds no code and no balance on L2, and no relationship to
a key. Deploying there needs a CREATE2 preimage over 160 bits. `test_C1_aliased_l1_messenger_has_no_code_on_l2`.

One correction to the usual telling of this story: `finalizeBridgeETH` requires
`msg.value == _amount`, so the ETH path is a pass-through and cannot be used to withdraw the bridge's
own balance. The value-bearing path on L2 is ERC20 minting. The first version of this test asserted a
drain and failed on exactly that point, which is why the assertion now targets the mint.

The mint PoC deploys its own token, so it proves the authorisation, not a profit. The gap is stated
in §4 rather than papered over.

## 3. Observations

### O-1 — L2 predeploy governance is a different address, and not a contract on either chain

| | Address | Code on L1 | Code on L2 |
|---|---|---|---|
| L1 ProxyAdmin owner | `0x1Eb2fFc903729a0F03966B917003800b145F56E2` | 171 bytes | — |
| L2 ProxyAdmin owner | `0x2FC3ffc903729a0f03966b917003800B145F67F3` | 0 | 0 |

The superchain registry lists one `ProxyAdminOwner`; the L2 predeploys are owned by a second address
that is not deployed on Sepolia. The same address owns the L2 predeploys on Unichain Sepolia, while
OP Mainnet (`0x6B1B…4E3b`) and Base Sepolia (`0x20f9…1Cba`) use different owners — so this is a
per-chain choice, not a shared constant, and the match between two OP-governed testnets suggests an
intentional testnet operations address rather than a mistake.

Consequence if the address is an EOA: every L2 predeploy upgrade is authorised by one key, with no
on-chain delay. On a testnet that is ordinary. On a mainnet deployment it would be a finding against
the governance model, not against the contracts. Do not publish this as a vulnerability before the
operator confirms intent.

### O-2 — 0.00167326735 ETH is stranded at the aliased messenger address

`alias(0x58Cc…b3ef)` on L2 holds `1,673,267,350,000,000` wei and no code. The address cannot spend,
so the funds are burned. It is a small but useful signal: something computed the L1 messenger's L2
address and sent value to it, which is exactly the mistake that a contract authorising on the alias
would make. Informational.

### O-3 — the L1 messenger is still a legacy resolved proxy

`0x58Cc…b3ef` has no EIP-1967 implementation or admin slot; its 799-byte runtime contains
`getAddress(string)` (`0xbf40fac1`) and resolves its implementation through the AddressManager on
every call. `version()` returns `2.13.0`, so resolution works.

Two consequences. Tooling that assumes EIP-1967 will report "no implementation" and may treat the
proxy as unverified. And the upgrade entry point is `AddressManager.setAddress`, not
`ProxyAdmin.upgrade` — an operator checklist that only looks at ProxyAdmin misses it. The
AddressManager's own owner was not read in this pass.

## 4. Not covered

| Item | Why |
|---|---|
| E2 implementation vs verified source | needs a byte-identical build; not reproduced here |
| B2 reorg / output-root handling | fault-proof internals are out of scope |
| B3 failed-withdrawal retry | no historical failed withdrawal was replayed |
| C2 L2→L1 sender as seen on L1 | needs a real withdrawal proof; reasoned from source only |
| D3 fee-on-transfer / rebasing tokens | the bridge credits the requested amount, not the received amount; a listing issue, not exercised |
| G1 / G3 | failed-message replay and forced inclusion not exercised |
| E4 role enumeration | guardian read; full holder set not enumerated |
| Gas constants across versions | L1 messenger 2.13.0 and L2 messenger 2.2.1 each carry the other side's relay budget; the two tables were not compared |

## 5. What this is not

- Not a bug bounty submission. The target is a testnet and nothing here is exploitable.
- Not a claim that the standard bridge is unreviewed or unsafe. The opposite: it survived the checks.
- Not a substitute for the operator's own runbook. O-1 and O-3 are operational, not code defects.
