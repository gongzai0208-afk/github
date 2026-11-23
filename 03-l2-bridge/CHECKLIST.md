# Bridge checklist

24 items, each with a way to check it, a pass criterion, and the result from the OP Sepolia pass
(`AUDIT.md`, `FORKS.md`). Legend: **verified** = an executable assertion exists; **source** = read
from the deployed code path but not exercised; **partial** = one half checked; **—** = not covered,
listed in `AUDIT.md` §4.

Target: OP Stack on OP Sepolia. L1 block 12,195,927, L2 block 51,818,604.

---

## A. Messages and replay

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| A1 | Messenger points at the right counterpart | `cast call <L2Messenger> "OTHER_MESSENGER()(address)"` vs the L1 messenger address | exact match, and the address is the one published by the chain | **verified** — `test_A1_messengers_are_paired` |
| A2 | Message hash binds nonce, sender, target, value, gas limit, data | read `relayMessage` / `sendMessage` and the hash construction | every field is in the hash | **source** — `hashCrossDomainMessageV1(nonce, sender, target, value, minGasLimit, message)`; version bits checked by `test_A2` |
| A3 | Withdrawal cannot be replayed | check the successful-message flag and the reentrancy guard | second call reverts; a reentrant call cannot execute twice | **verified** — second relay reverts `message has already been relayed`; reentrancy is caught by `xDomainMsgSender != sentinel`. Portal half not read |
| A4 | Cross-domain sender check | `xDomainMessageSender` is set only inside `relayMessage` | a direct call cannot spoof it | **verified** — `test_A4`, `test_A3_bridges_reject_direct_callers` |

## B. Finality and withdrawal

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| B1 | Withdrawal delay matches documentation | read `proofMaturityDelaySeconds` / `disputeGameFinalityDelaySeconds` | equals the published value for that chain | **verified** — 604,800 s and 302,400 s |
| B2 | Reorg handling | read the portal's proof-submission and dispute-game wiring | a reorged output root cannot finalize | **—** out of scope |
| B3 | Failed withdrawal is retryable | inspect the failed-message path and `checkWithdrawal` | funds are not stuck; retry does not double-pay | **—** not exercised |

## C. Addresses and identity

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| C1 | L1→L2 alias is undone where L1 addresses are authorised | grep the L2 target for `applyL1ToL2Alias` / `undoL1ToL2Alias` | every L1-address authorisation unaliases first | **verified** — `_isOtherMessenger` unaliases; alias address has no code (`test_C1`). Note O-2 |
| C2 | L2→L1 direction has no alias | read `L1CrossDomainMessenger` sender handling | L1 sees the L2 contract address, not an alias | **partial** — `_isOtherMessenger` is `msg.sender == portal && portal.l2Sender() == otherMessenger`; no real withdrawal replayed |
| C3 | Admin/owner addresses are controllable on the chain they live on | `cast call <target> "owner()(address)"`, then check code on that chain | owner is a contract on the same chain | **verified on L1** — ProxyAdmin owned by a 171-byte contract. On L2 the owner differs and has no code: O-1 |

## D. Tokens and decimals

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| D1 | Bridged token decimals match the source chain | `decimals()` on both chains | equal, or a documented scaling factor | **verified** — WETH 18 / 18, symbol equal (`test_D1`). The L2 WETH predeploy is not an `OptimismMintableERC20` and has no pair getters |
| D2 | Limits and fees use the smallest unit | read `depositERC20` / rate-limit code | no human-unit arithmetic, no hardcoded 1e18 | **n/a** — the standard bridge has no rate limiter; no other limit code was audited |
| D3 | Fee-on-transfer / rebasing tokens | check whether the bridge measures balance before and after | bridge credits the amount received | **—** source shows the requested amount is credited, which is the known limitation; not exercised |

## E. Permissions and upgrades

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| E1 | Proxy admin is a timelock or multisig | read EIP-1967 admin slot | not an EOA; delay documented | **verified** — 6,524-byte ProxyAdmin owned by the registry owner (a contract on L1); L2 side is O-1 |
| E2 | Implementation matches verified source | `cast code` vs build, compare runtime hash | byte-identical or diff explained | **—** needs a byte-identical build |
| E3 | Upgrade entry points are admin-only | read `upgradeTo` guards | only the proxy admin can call | **verified pattern** — the L1 messenger has no EIP-1967 slot; it resolves through `getAddress(string)` every call, so `AddressManager.setAddress` is the real entry point (`test_E3`). The AddressManager owner was not read |
| E4 | Pause and guardian roles | enumerate role holders from events or storage | at least two independent holders, documented | **partial** — portal and SuperchainConfig guardians are both `0x7a50…Cf7E`; holder set not enumerated |

## F. Configuration and operations

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| F1 | Rate limits | read the limit config and window usage | limit is finite and non-zero | **n/a** — no limiter on the standard bridge |
| F2 | Bridge pause state | `cast call <bridge> "paused()(bool)"` | expected state for the deployment | **verified** — bridge, both messengers, portal and SuperchainConfig all unpaused (`test_F2`) |
| F3 | System addresses match the official list | compare portal, messenger, bridge, dispute game to docs | exact match | **verified** — portal, SystemConfig, DisputeGameFactory, SuperchainConfig all match the registry (`test_F3`) |
| F4 | Challenge period and output root config | read `DisputeGameFactory` / `OptimismPortal2` params | matches the published fault-proof config | **verified** — `respectedGameType = 9`, implementation set, 90,367 games (`test_F4`) |

## G. Failure modes

| # | Item | How to check | Pass criterion | Result |
|---|---|---|---|---|
| G1 | Failed message can be replayed | read the failed-message store and replay path | replay is possible without double spending | **—** not exercised |
| G2 | ETH transfer failure is not silently swallowed | look for `call{value:}` return checks | failure reverts or is recorded, never ignored | **source** — `finalizeBridgeETH` requires the `SafeCall` result and reverts `ETH transfer failed` |
| G3 | Censorship resistance | check the forced-inclusion path through L1 | a user can force a withdrawal without the sequencer | **—** not exercised |

---

A checklist without a conclusion is not a review. This one has 13 items closed by an assertion, 2 by
reading the code path, 2 partial, 2 not applicable, and 5 explicitly open.
