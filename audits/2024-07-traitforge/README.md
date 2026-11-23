# Smart Contract Security Review — TraitForge NFT System

**Reviewed commit:** `279b2887e3d38bc219a05d332cbcb0655b2dc644`
**Repository:** `code-423n4/2024-07-traitforge`
**Scope:** 6 contracts, 880 nSLOC (1,227 physical lines — both under the 1,500-line gate; the 880 figure is Code4rena's nSLOC count, not a raw line count)
**Date:** November 2026

---

## 1. Executive Summary

This review covers the TraitForge NFT system: an ERC-721 collection with generational minting, entity forging, a secondary trading market, an on-chain entropy generator, and a treasury ("NukeFund") that pays out when tokens are burned.

The review combined line-by-line manual inspection with Foundry proof-of-concept tests. **Eleven issues are reported: 2 High, 6 Medium, 3 Low.** The two High findings, and F-10 (Medium), are demonstrated on the real wiring — real `EntropyGenerator`, real `EntityForging`, only the airdrop stubbed. All twelve tests were re-run against a patched build: every finding has at least one test that fails (11/11), and F-10 has a second test (P11) that fails at the same step, so it corroborates rather than adds an independent data point. Of the twelve, four fail by reverting, six on a state assertion, and two because an expected revert did not happen. The appendix records the exact observed failure for each. The test suite is in [`test/`](test/) and runs with a single command.

| ID | Severity | Title |
|---|---|---|
| F-01 | High | Generation limit is never enforced — supply can grow without bound |
| F-02 | Medium | Batch minting is permanently disabled once total supply reaches 10,000 |
| F-03 | High | Generation rollover erases forged pre-fills and lets a generation exceed its cap |
| F-04 | Medium | Price is computed before the rollover, overcharging the first mint of every generation |
| F-05 | Medium | Excess forging payment is locked in the contract forever |
| F-06 | Medium | Forgers can be forged one time more than their stated potential |
| F-07 | Medium | Burning a token debits the original minter's airdrop allocation, not the current owner's |
| F-08 | Low | The pause mechanism is unreachable in every contract |
| F-09 | Low | Treasury address can be set to `address(0)`, silently burning mint proceeds |
| F-10 | Medium | Generation rollover requires entropy ownership, and that ownership removes the admin |
| F-11 | Low | `taxCut` is used as a divisor, so any value other than 10 mis-splits every fee, and 0 disables three contracts |

The dominant theme is not exotic exploitation. It is **state accounting that disagrees with itself**: a loop bounded by a global counter instead of a per-generation counter, a generation counter zeroed while another function may have already written to it, a price read one step before the generation changes. Each of these is a few lines apart in the same file. Most produce a quantifiable loss or an accounting break; three of them (F-02, F-08, F-10) are availability and control defects rather than direct loss.

---

## 2. Scope

| File | Lines | git blob SHA-1 |
|---|---|---|
| `contracts/TraitForgeNft/TraitForgeNft.sol` | 396 | `a17de61b961e7289d15aaf775e949dc52dc9c31a` |
| `contracts/EntityForging/EntityForging.sol` | 208 | `c9ce23b70f6eb7543408134d2efe15800b7cbc85` |
| `contracts/EntropyGenerator/EntropyGenerator.sol` | 217 | `3c10979ebe4fa3dc1605e4880c4c65706b4e3913` |
| `contracts/NukeFund/NukeFund.sol` | 195 | `953d7cfed586c3879a68444b5aabc3bcea1a5f46` |
| `contracts/EntityTrading/EntityTrading.sol` | 118 | `57a6b079a486f553f66e199157b6e4f2ee469389` |
| `contracts/DevFund/DevFund.sol` | 93 | `671b578159072af86aee6f4847723fa62e3a0323` |

**Compiler:** solc 0.8.25 (`pragma solidity ^0.8.20` in all six files).
**Dependencies:** OpenZeppelin Contracts v4.9.3 (`Pausable`, `ReentrancyGuard`, `Ownable`, ERC-721 extensions, `MerkleProof`), pinned by the project's `package.json`.

The external `Airdrop` implementation is referenced only through `IAirdrop` and is **not** in scope. Where a finding depends on its behaviour, that dependency is stated explicitly.

---

## 3. Severity Classification

| Severity | Definition used here |
|---|---|
| **High** | Loss of user funds, or a broken core invariant, reachable through the documented flow with well-formed input, where neither the victim's own wrong amount nor a privileged role setting an invalid value is required. |
| **Medium** | Bounded or self-inflicted value loss (an overpayment, stranded dust, an overcharge at a generation boundary), economic distortion, or denial of service under normal use. |
| **Low** | Requires a privileged role to set an invalid value first (misconfiguration), a dead safety mechanism, or no direct fund loss. |

A privileged call still counts as the documented flow when the contract itself validates that input; a wrong value is excluded from High only where the code performs no check on it. That is the difference between an owner call that trips a broken guard (StakingRewards F-01) and an owner call that sets an unchecked invalid value (F-09 and F-11 here).

---

## 4. Findings

### F-01 — Generation limit is never enforced

**Severity:** High
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — `_incrementGeneration()` at L345–355; contrast with the check in `forge()` at L166

**Description.**
`maxGeneration` is declared as `10` (L35). The only place it is checked is the forge path:

```solidity
// TraitForgeNft.sol:166
require(newGeneration <= maxGeneration, "Exceeds max generations");
```

The function that actually advances the generation does not check it:

```solidity
// TraitForgeNft.sol:345-355
function _incrementGeneration() private {
  require(generationMintCounts[currentGeneration] >= maxTokensPerGen, 'Generation limit not yet reached');
  currentGeneration++;
  generationMintCounts[currentGeneration] = 0;
  priceIncrement = priceIncrement + priceIncrementByGen;
  entropyGenerator.initializeAlphaIndices();
  emit GenerationIncremented(currentGeneration);
}
```

`_mintInternal` (L280–283) calls it unconditionally once the current generation is full. A public mint therefore walks past the cap.

**Impact.**
The advertised 10 × 10,000 = 100,000 token ceiling does not exist. Minting continues indefinitely at the current price progression. Any downstream assumption — scarcity, a fixed airdrop pool, or off-chain supply accounting — is invalidated.

**Proof of Concept.**
`test_PoC_P4_generationExceedsMaxGeneration` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol). State is placed at the boundary (`currentGeneration = 10`, `generationMintCounts[10] = 10000`), then a single public mint is made.

Observed: the mint succeeds, `currentGeneration` becomes **11**, and the new token is recorded in generation 11. With the check in place the call would revert.

**Recommendation.**
Add the bound where the state changes, not only in the forge path:

```solidity
function _incrementGeneration() private {
  require(currentGeneration < maxGeneration, "Exceeds max generations");
  ...
}
```

and revert the mint when the cap is reached rather than silently advancing.

---

### F-02 — Batch minting is permanently disabled once total supply reaches 10,000

**Severity:** Medium (no loss of funds: the call refunds in full and single mints keep working; what breaks is the batch path)
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — loop guard at L215; per-generation cap at L281; global counter incremented at L285 and L321

**Description.**
`mintWithBudget` loops while a **global** counter is below a **per-generation** limit:

```solidity
// TraitForgeNft.sol:215
while (budgetLeft >= mintPrice && _tokenIds < maxTokensPerGen) {
```

`_tokenIds` is monotonically increasing across all generations (L285) and is also incremented by the forge path (L321). `maxTokensPerGen` is 10,000. Once the contract has ever created 10,000 tokens — by minting, forging, or any combination — the condition is permanently false and the loop body never executes.

**Impact.**
From that point on `mintWithBudget` accepts the caller's ETH, mints nothing, and refunds in full: it is a gas-burning no-op for the rest of the contract's life, even though generation 2 and later are still open for single mints. Any integration or UI that relies on batch minting breaks without an error.

**Proof of Concept.**
`test_PoC_P2_mintWithBudgetDeadAfterMaxSupply` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol). Control first: 0.05 ETH mints 9 tokens. Then `_tokenIds` is placed at 10,000 and 1 ETH is sent.

Observed: tokens minted = **0**, `totalSupply` unchanged at 9, caller's ETH delta = **0** (full refund), contract balance 0.

**Recommendation.**
Bound the loop by the quantity that the cap actually applies to:

```solidity
while (budgetLeft >= mintPrice && generationMintCounts[currentGeneration] < maxTokensPerGen) {
```

or split the loop on the remaining capacity of the current generation.

---

### F-03 — Generation rollover erases forged pre-fills and lets a generation exceed its cap

**Severity:** High
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — reset at L350–351; writes to a future generation at L311–343; generation argument from the forge path at L163

**Description.**
`_incrementGeneration` unconditionally zeroes the counter of the generation it just entered:

```solidity
// TraitForgeNft.sol:350-351
currentGeneration++;
generationMintCounts[currentGeneration] = 0;
```

But `_mintNewEntity` accepts an arbitrary `gen` and increments `generationMintCounts[gen]` (L328). The forge path passes `gen = parentGeneration + 1` (L163), so entities can be forged into a generation that has not started yet. When that generation later begins, those counts are discarded.

**Impact.**
Two consequences, both economic. First, the per-generation cap is breached by exactly the number of pre-filled entities (they occupy no budget in the counter that is used to enforce the cap). Second, the price curve of the new generation restarts as if nothing had been forged, undercharging for the tokens that follow.

**Proof of Concept.**
`test_PoC_P3_generationCountWipedOnRollover` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol). State: `currentGeneration = 1`, `generationMintCounts[1] = 10000`, `generationMintCounts[2] = 42` (42 entities already forged into generation 2). One public mint triggers the rollover.

Observed: after the rollover `generationMintCounts[2] == 1` — the 42 pre-fills were zeroed and only the new mint counted. Remaining capacity for generation 2 is 9,999 instead of the intended 9,957. A fixed implementation would report 43.

**Recommendation.**
Do not reset a counter that another path may already have written. Either:

- reject forging into a generation that has not started (`require(gen == currentGeneration)`), or
- stop zeroing and treat `generationMintCounts[currentGeneration]` as authoritative from deployment.

---

### F-04 — Price is computed before the rollover, overcharging the first mint of every generation

**Severity:** Medium
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — price read at L190; rollover inside `_mintInternal` at L281–283; price formula at L227–232

**Description.**
`mintToken` reads the price before calling into the mint function:

```solidity
// TraitForgeNft.sol:190-193
uint256 mintPrice = calculateMintPrice();
...
_mintInternal(msg.sender, mintPrice);
```

`_mintInternal` may advance the generation first (L281–283) and only then mint into the **new** generation. The price charged is the last price of the **old** generation, which is the maximum of that generation's curve.

**Impact.**
The boundary mint of every generation is overcharged. With the shipped constants, generation 1 ends at `0.005 + 0.0000245 × 10000 = 0.25 ETH`, while the first token of generation 2 should cost `0.005 ETH`. The user pays 50× the correct price for one token per generation, and the proceeds go to the treasury, not back to the user.

**Proof of Concept.**
`test_PoC_P6_priceOverchargeAtGenerationRollover` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol). State: `currentGeneration = 1`, `generationMintCounts[1] = 10000`.

Observed: 0.25 ETH is charged and forwarded to the treasury, while the token is minted into generation 2, whose correct first price is 0.005 ETH. Overcharge: **0.245 ETH**. The increment for the next generation is 0.0000295 ETH, confirming the rollover happened after pricing.

**Recommendation.**
Compute the price after the rollover decision, or move the rollover ahead of the price read:

```solidity
if (generationMintCounts[currentGeneration] >= maxTokensPerGen) _incrementGeneration();
uint256 mintPrice = calculateMintPrice();
```

---

### F-05 — Excess forging payment is locked in the contract forever

**Severity:** Medium
**Location:** `contracts/EntityForging/EntityForging.sol` — acceptance at L126; distribution at L146–159

**Description.**
The function accepts any payment at or above the fee:

```solidity
// EntityForging.sol:126
require(msg.value >= forgingFee, 'Insufficient fee for forging');
```

but distributes exactly the fee:

```solidity
// EntityForging.sol:146-147
uint256 devFee = forgingFee / taxCut;
uint256 forgerShare = forgingFee - devFee;
```

There is no `receive`, `fallback`, withdrawal, or rescue function in the contract. Anything above `forgingFee` stays in the contract's balance permanently.

**Impact.**
User funds are irrecoverably locked. The condition is ordinary: a wallet or integration that sends a rounded amount, a fee lowered between listing and execution, or a retry with a stale quote all produce a stranded remainder. There is no error, event, or refund path.

**Proof of Concept.**
`test_PoC_P1_excessPaymentLocked` in [`test/EntityForgingPoC.t.sol`](test/EntityForgingPoC.t.sol). A forger is listed with a 1 ETH fee and the merger sends 3 ETH.

Observed: the forger owner receives 0.9 ETH, the treasury receives 0.1 ETH, and `address(EntityForging).balance == 2 ETH` afterwards. A call to `withdraw()` reverts (no such selector) and the 2 ETH remains.

**Recommendation.**
Refund the difference, or require exact payment:

```solidity
require(msg.value == forgingFee, 'Incorrect fee');
// or
uint256 refund = msg.value - forgingFee;
if (refund > 0) { (bool ok, ) = msg.sender.call{value: refund}(''); require(ok, 'Refund failed'); }
```

---

### F-06 — Forgers can be forged one time more than their stated potential

**Severity:** Medium
**Location:** `contracts/EntityForging/EntityForging.sol` — listing check at L87–90; increment without re-check at L133

**Description.**
The listing check uses a non-strict comparison against the pre-increment value:

```solidity
// EntityForging.sol:87-90
require(forgingCounts[tokenId] <= forgePotential, ...);
```

The execution path only increments:

```solidity
// EntityForging.sol:133
forgingCounts[forgerTokenId]++;
```

A forger with potential `P` can therefore be used `P+1` times: the listing is accepted while the counter equals `P`, and the subsequent forge takes it to `P+1` without any post-increment validation. (The merger side is checked correctly after the increment at L140–144, which is what makes the asymmetry visible.)

**Impact.**
Each forger produces one more child token than the model allows, inflating supply and the associated airdrop allocation. For a generation of forgers with high potential, the overshoot compounds across the whole generation.

**Proof of Concept.**
`test_PoC_P5_forgerUsedPotentialPlusOne` in [`test/EntityForgingPoC.t.sol`](test/EntityForgingPoC.t.sol). A forger whose entropy yields `forgePotential = 2` is listed once and forged three times with distinct mergers.

Observed: all three forges succeed and `forgingCounts(1) == 3`, i.e. `P+1`.

**Recommendation.**
Use a strict comparison, or validate after the increment as the merger path does:

```solidity
require(forgingCounts[tokenId] < forgePotential, ...);
```

---

### F-07 — Burning a token debits the original minter's airdrop allocation, not the current owner's

**Severity:** Medium
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — burn path at L146–149; `initialOwners` written at L294 and L329, never updated on transfer

**Description.**
On burn, the contract deducts from the airdrop allocation of the **first** owner:

```solidity
// TraitForgeNft.sol:146-149
if (!airdropStarted) {
  airdropContract.subUserAmount(initialOwners[tokenId], tokenEntropy[tokenId]);
}
```

`initialOwners[tokenId]` is written only at mint time and is not updated by transfers. The current owner, who is the one burning and the one who paid for the token, is not consulted.

**Impact.**
A buyer can burn a purchased token and reduce a third party's allocation — the original minter's — while keeping their own intact. This is a griefing vector that costs the attacker only gas, and it can be repeated on every token the attacker buys. It also means the reduction is attributed to the wrong account, so any accounting built on top of `subUserAmount` is wrong by construction.

**Proof of Concept.**
`test_PoC_P7_burnDebitsOriginalMinter` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol). A mock airdrop records debit calls. Alice mints, transfers to Bob, Bob burns.

Observed: the recorded debit is attributed to **Alice** (the initial minter), not Bob (the burner and current owner).

**Recommendation.**
Debit the current owner:

```solidity
airdropContract.subUserAmount(ownerOf(tokenId), tokenEntropy[tokenId]);
```

and clarify in the airdrop contract whether allocation follows the token or the account.

---

### F-08 — The pause mechanism is unreachable in every contract

**Severity:** Low (a dead safety mechanism, no direct loss)
**Location:** all six contracts inherit OpenZeppelin `Pausable`; no contract exposes `pause()` / `unpause()`

**Description.**
Every contract applies `whenNotPaused` to its state-changing entry points and inherits `Pausable`, but none of them defines or exposes `pause()` or `unpause()`. In OpenZeppelin 4.9.x both `_pause()` and `_unpause()` are `internal`, so they are unreachable unless a contract exposes them.

**Impact.**
The emergency stop does not exist. Every `whenNotPaused` modifier is dead code, and `paused()` always returns `false`. If an incident occurs, the owner has no way to halt minting, forging, trading, or nuke payouts while a fix is prepared.

**Proof of Concept.**
Static: the other five contracts show the same pattern by inspection. The executable part of this finding covers `TraitForgeNft` only: `test_PoC_P8_pauseUnreachable` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol) makes one low-level call to the `pause()` selector, observes it revert, and checks `paused()` stays false. The claim "no pause entry point in any of the six contracts" is a reading-level claim for the other five.

**Recommendation.**
Expose pausing to a role that is not the same key as the treasury operator:

```solidity
function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
```

---

### F-09 — Treasury address can be set to the zero address, silently burning mint proceeds

**Severity:** Low
**Location:** `contracts/TraitForgeNft/TraitForgeNft.sol` — setter at L66–71; payment at L361

**Description.**
`setNukeFundContract` performs no validation, and `_distributeFunds` moves ETH with a low-level call:

```solidity
// TraitForgeNft.sol:361
(bool success, ) = nukeFundAddress.call{value: mintPrice}('');
require(success, 'Transfer to NukeFund failed');
```

A call to `address(0)` returns `true`, so a misconfigured treasury address results in every mint payment being destroyed rather than reverted. `EntityForging.setNukeFundAddress` (L30–34) has the same gap for the fee share.

**Impact.**
Mint proceeds and forging fees are burned without any error. The failure is silent at the transaction level and only visible as a missing balance in the treasury.

**Proof of Concept.**
`test_PoC_P9_zeroTreasuryBurnsFunds` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol): with the treasury set to `address(0)`, a mint succeeds and the ETH is no longer held by any contract.

**Recommendation.**
```solidity
require(newNukeFund != address(0), 'Zero address');
```
in both setters.

---

### F-10 — Generation rollover requires entropy ownership, and that ownership removes the admin

**Severity:** Medium (no loss of funds; the halt lasts until the owner transfers ownership, and the transfer itself is a privileged configuration step)
**Location:** `contracts/EntropyGenerator/EntropyGenerator.sol` — `initializeAlphaIndices()` at L206 (`whenNotPaused onlyOwner`); call site `contracts/TraitForgeNft/TraitForgeNft.sol` — `_incrementGeneration()` at L353

**Description.**
The rollover path calls a function that the caller is not allowed to call:

```solidity
// TraitForgeNft.sol:353
entropyGenerator.initializeAlphaIndices();
```

```solidity
// EntropyGenerator.sol:206
function initializeAlphaIndices() public whenNotPaused onlyOwner {
```

The generator is deployed separately. Its constructor sets `allowedCaller = _traitForgetNft` (L30–33) but leaves `Ownable.owner` as the deployer, so the NFT is the *allowed caller* and never the *owner*. Every mint that fills a generation therefore reverts at the rollover — until the owner transfers ownership of the generator to the NFT.

The documented workaround is that transfer. It fixes the rollover, but it gives the generator an owner that is a contract: `setAllowedCaller` (the only role-rotation function) and every `onlyOwner` function added later — including the `pause()` proposed in F-08 — become callable only by `TraitForgeNft`, which has no path to forward them. The transfer grants the NFT nothing it does not already have: it is already `allowedCaller` from the constructor. All it does is delete the administrator.

**Impact.**
The deployment has to choose between two unwanted states:

- **No transfer** — minting stops at 10,000 tokens (the end of generation 1) until the owner transfers ownership. The 100,000-token model, which is the product's advertised supply, is unreachable while the misconfiguration lasts; the failure lands exactly at the generation boundary, after a full generation has been sold. No funds are lost: every failed mint reverts.
- **Transfer** — minting continues, but the generator has no reachable administrator for the rest of its life. The allowed-caller role cannot be rotated if the NFT is replaced or a second minter is added, and no emergency stop can be installed on the contract that feeds every mint.

Both are recoverable in principle (transfer ownership, or redeploy the generator), so this is a design and deployment hazard rather than a permanent loss. What makes it a finding and not a note is that the two properties the protocol needs — "the NFT can trigger the rollover" and "a human can administer the generator" — are mutually exclusive in the code as written: no deployment configuration of these two contracts provides both, and a fix requires a code change (the patch below).

**Proof of Concept.**
`test_PoC_P10_rolloverRevertsWithoutOwnershipTransfer` in [`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol): real wiring, ownership not transferred. Observed: `generationMintCounts[1]` is set to the cap, and the next mint reverts with `Ownable: caller is not the owner`; `currentGeneration` stays 1 and no token is minted.

`test_PoC_P11_ownershipTransferStrandsEntropyAdmin`: same wiring and same first leg (the rollover mint must revert), then `entropy.transferOwnership(nft)` (from the deploying helper, the current owner). Observed: the transfer succeeds, `entropy.owner()` becomes the NFT contract, and `setAllowedCaller` called by the deployer reverts with `Ownable: caller is not the owner`. The first leg duplicates P10 on purpose — it establishes that the transfer is not optional — so against `fixes/F-10/` this test fails at that leg and the second leg is not reached. P11 documents the consequence; it is not a second independent demonstration of the finding.

**Recommendation.**
Give the NFT a caller role instead of ownership — `allowedCaller` already exists and already points at the NFT:

```solidity
modifier onlyOwnerOrAllowedCaller() {
  require(msg.sender == owner() || msg.sender == allowedCaller, 'Caller is not allowed');
  _;
}

function initializeAlphaIndices() public whenNotPaused onlyOwnerOrAllowedCaller { ... }
```

and drop the ownership transfer from the deployment procedure. This is the patch in `fixes/F-10/`; with it, F-08's `pause()` remains reachable.

---

### F-11 — `taxCut` is used as a divisor, so any value other than 10 mis-splits every fee, and 0 disables three contracts

**Severity:** Low (requires the owner to set the parameter; at the deployed value of 10 the split is correct)
**Location:** `contracts/EntityForging/EntityForging.sol` L146; `contracts/EntityTrading/EntityTrading.sol` L72; `contracts/NukeFund/NukeFund.sol` L41. Setters: EF L36, ET L33, NF L63.

**Description.**
`taxCut` is documented as a percentage — the default is `10`, commented as "10%" — but every use divides by it:

```solidity
// EntityForging.sol:146
uint256 devFee = forgingFee / taxCut;
// EntityTrading.sol:72
uint256 nukeFundContribution = msg.value / taxCut;
// NukeFund.sol:41
uint256 devShare = msg.value / taxCut;
```

`x / 10` equals `x × 10%` only because `10 == 100 / 10`. Change the cut and the split inverts: a 5% cut turns into 20%, a 20% cut into 5%. Set it to zero and all three divisions revert, taking the forge path, the trading path and the fund's payout path with them. The three setters (`setTaxCut`, `onlyOwner`) perform no validation.

**Impact.**
A privileged parameter change silently misroutes every fee in all three contracts, and a zero value disables them. No external attacker can trigger it: the deployed value is correct, so the bug is dormant until the owner changes it — which is why it is reported as Low here even though the same issue was rated High in the project's published findings (see the rating-difference table in §5).

**Proof of Concept.**
`test_PoC_P12_taxCutDivisorMisprices` in [`test/EntityForgingPoC.t.sol`](test/EntityForgingPoC.t.sol). With `taxCut = 5`, a 1 ETH forge pays the treasury **0.2 ETH** (20%) and the forger **0.8 ETH** instead of 0.05 / 0.95. Then `taxCut = 0` and the next forge reverts on the division.

**Recommendation.**
Multiply, and bound the setter:

```solidity
uint256 devFee = (forgingFee * taxCut) / 100;
// in all three setters
require(_taxCut > 0 && _taxCut <= 100, 'Invalid tax cut');
```

The patch is `fixes/F-11/` (three formulas, three setters).

---

## 5. Out of Scope and Limitations

- **Airdrop contract.** Only the `IAirdrop` interface is available; the implementation is not part of this review. F-07's impact depends on how `subUserAmount` handles an underflow, which could not be verified. The PoC stubs it with a mock that records calls; that mock is the only stub on an otherwise real wiring.
- **Entropy ownership (F-10).** The generator must be callable by the NFT and administrable by a human at the same time; the shipped access control makes those mutually exclusive. P10 measures the first failure mode (rollover blocked while the deployer keeps ownership) and P11 the second (transfer unblocks it and leaves no external owner). Both run on the real wiring.
- **Wiring used by the PoCs.** P3, P4, P6, P10 and P11 run against the real `EntropyGenerator` (all entropy batches written and alpha indices initialised while the deployer still owned it, then ownership transferred last, or deliberately not transferred) and the real `EntityForging`; only the airdrop is stubbed there. P7 keeps `MockEntropyGenerator` because it needs a chosen entropy value. **P2, P7, P8 and P9 run on a lighter fixture** — `MockForgingRegistry` plus mock entropy — because they exercise the NFT contract in isolation; P5 reads its forger properties from the entropy stream, so it is not entropy-free even though it does not touch the generator directly. The claim "only the airdrop is stubbed" applies to the P3/P4/P6/P10/P11 group, not to the suite as a whole.
- **Injected state, per test.** P3 obtains its generation-2 count (8 — the forger's potential in the sampled stream) through eight real `forgeWithListed` calls, then marks generation 1 as full and leaves `_tokenIds` equal to the real token count. P6 marks generation 1 as full only. P4 is the weakest of the set: it writes `currentGeneration = 10` and `generationMintCounts[10] = 10000` and **nothing else** — `priceIncrement`, the counts of generations 1–9 and the token supply are all left inconsistent with that state, so it is a single fast-forwarded counter, not a reachable configuration. The assertions that follow do not depend on those invariants, but P4 should be read as "the code path has no upper bound", not as a reachable end-to-end scenario. P2 sets `_tokenIds` to 10,000, which is a reachable value. The earlier version of P3 wrote its pre-fills directly into storage; that is fixed.
- **Provenance.** The findings came from two passes over the frozen sources with the published findings held back, and the PoCs were written afterwards. The code and the answers are both public (Code4rena 2024-07), so the isolation was procedural, not enforceable: model memorisation of a public contest cannot be ruled out, and this report should not be read as proof that the same findings appear without the answer key. Eight of the nine findings that existed at freeze time coincide with the published set; **F-10 and F-11 were added during the final cross-check** and are labelled as such.
- **Rating differences from the published set.** Five findings are rated differently here; the reasons, not just the labels:

| Published | Here | Published severity | Here | Why |
|---|---|---|---|---|
| H-01 batch mint dies at 10k | F-02 | High | Medium | The call refunds in full and single mints keep working; only the batch entry point is dead. No funds are at risk. |
| H-02 airdrop griefing on a sold token | F-07 | High | Medium | The debit hits a third party's airdrop allocation, not principal, and the attacker gains nothing; the airdrop implementation is out of scope, so the worst case (underflow reverting the burn) could not be measured. |
| H-03 `taxCut` divisor | F-11 | High | Low | Only reachable after the owner changes a parameter; the deployed value (10) yields the intended split. Reported because a mis-set value silently misroutes fees and 0 disables three contracts — but it is a misconfiguration, not an attacker path. |
| H-06 rollover DoS | F-10 | High | Medium | The halt is recoverable by the owner (`transferOwnership`) and loses no funds. |
| M-13 pause inaccessible | F-08 | Medium | Low | A dead safety mechanism with no direct loss. |

  The rule is printed in §3 and applied in the same way in all three reports: a finding that needs a privileged role to set an invalid value is Low, and a finding whose loss is self-inflicted or bounded is Medium, whatever the published rating says.

- **No fuzzing or invariant campaign** was run. Findings are from manual review plus targeted execution.
- **Severity is an assessment**, not an on-chain fact.
- **Fix-fail status: 11/11 findings measured (12 tests).** Each finding has a patched source tree under `fixes/F-0x/`, and every finding has at least one test that fails against its patch. F-10 has two tests: P10 and P11 both fail, but they fail at the same step, so P11 is corroborating evidence, not a second independent data point. **Four** tests fail by reverting (P4 / F-01 `Exceeds max generations`, P1 / F-05 `Incorrect fee`, P5 / F-06 `Entity has reached its forging limit`, P9 / F-09 `Zero address`); **six** fail on a state assertion (P2, P3, P6, P7, P8, P12); **two** fail because an expected revert did not happen (P10, P11), which is weaker — it shows the guard is gone, not that the harm was asserted. F-03's fix-fail uses the "stop zeroing" variant; the "reject forging into a future generation" fix would abort the setup instead. Fix-fail proves a PoC is sensitive to *a* patch; it does not prove the patch is correct. The combined patch is tested separately: `fixes/ALL/` holds all eleven fixes merged, all twelve tests fail there, and [`test/Regression.t.sol`](test/Regression.t.sol) checks that normal minting, forging, burning and the budget-mint path still work. Raw `forge test` output for every run is committed under `logs/`.

---

## 6. Appendix — PoC Suite

```bash
# inside this audit folder
forge test -vv
```

Environment: Foundry 1.8.5, solc 0.8.25, `via_ir = false`, OpenZeppelin 4.9.3.

| Test | Finding | Assertion | Fails when fixed? (verbatim log text) |
|---|---|---|---|
| `test_PoC_P1_excessPaymentLocked` | F-05 | 2 ETH of a 3 ETH payment remains in the contract | **yes** — `[FAIL: Incorrect fee]` (`fixes/F-05/`) |
| `test_PoC_P2_mintWithBudgetDeadAfterMaxSupply` | F-02 | 0 tokens minted, full refund, after `_tokenIds = 10_000` | **yes** — `[FAIL: mintWithBudget must mint nothing once _tokenIds >= maxTokensPerGen: 143 != 0]` (`fixes/F-02/`) |
| `test_PoC_P3_generationCountWipedOnRollover` | F-03 | 8 real forges into gen 2, then the count is reset: assertion expects 1 | **yes** — `[FAIL: generationMintCounts[2] was reset, erasing N entities (correct value is N+1): 9 != 1]` (`fixes/F-03/`, "stop zeroing" variant) |
| `test_PoC_P4_generationExceedsMaxGeneration` | F-01 | `currentGeneration` reaches 11 with `maxGeneration = 10` | **yes** — `[FAIL: Exceeds max generations]` (`fixes/F-01/`) |
| `test_PoC_P5_forgerUsedPotentialPlusOne` | F-06 | `forgingCounts == P+1` | **yes** — `[FAIL: Entity has reached its forging limit]` (`fixes/F-06/`) |
| `test_PoC_P6_priceOverchargeAtGenerationRollover` | F-04 | buyer's net spend is 0.25 ETH for a token priced 0.005 ETH | **yes** — `[FAIL: buyer net spend is the maxed-out generation-1 price: 5000000000000000 != 250000000000000000]` (`fixes/F-04/`; the numbers are wei) |
| `test_PoC_P7_burnDebitsOriginalMinter` | F-07 | debit attributed to the previous owner | **yes** — `[FAIL: burn debited the original minter: 0x000000000000000000000000000000000000cafE != 0x00000000000000000000000000000000000A11cE]` (`fixes/F-07/`) |
| `test_PoC_P8_pauseUnreachable` | F-08 | no `pause` / `unpause` in the ABI | **yes** — `[FAIL: pause() is reachable from outside]` after `fixes/F-08/` adds `pause()` |
| `test_PoC_P9_zeroTreasuryBurnsFunds` | F-09 | proceeds destroyed with a zero treasury | **yes** — `[FAIL: Zero address]` (`fixes/F-09/`) |
| `test_PoC_P10_rolloverRevertsWithoutOwnershipTransfer` | F-10 | rollover reverts when the NFT does not own the generator | **yes** — `[FAIL: next call did not revert as expected]` (`fixes/F-10/`: the rollover now succeeds) |
| `test_PoC_P11_ownershipTransferStrandsEntropyAdmin` | F-10 | after the transfer, no external account can call `setAllowedCaller` | **yes, but not independently** — `[FAIL: next call did not revert as expected]` at the first leg, i.e. at the same step as P10 (`fixes/F-10/`) |
| `test_PoC_P12_taxCutDivisorMisprices` | F-11 | a 5% `taxCut` should take 5%, not 20% | **yes** — `[FAIL: 5% cut is applied as a divisor: the treasury takes 20%: 50000000000000000 != 200000000000000000]` (`fixes/F-11/`) |

Reproduce any row, e.g.:

```bash
forge test --remappings 'traitforge/=fixes/F-03/src/' --match-test test_PoC_P3
# expect: [FAIL: generationMintCounts[2] was reset, erasing N entities (correct value is N+1): 9 != 1]
```

The failure text matters: a PoC that fails by reverting proves the fix changed behaviour, but not that the assertion itself is the thing that noticed. The same applies to the two rows whose failure is `next call did not revert as expected`: they show the vulnerable behaviour is gone, not that a state assertion caught it. Rows above quote what was actually observed; the raw runs are in `logs/baseline.txt` and `logs/fixfail-*.txt`.

### Combined patch

`fixes/ALL/src/` merges all eleven fixes. Merging eleven single-fix trees is not the same as testing them: two of these fixes change the same control flow (F-03 stops zeroing a counter; F-04 moves the rollover ahead of the price read and re-settles inside the budget loop; F-01's new bound runs inside the same function). That is not a theoretical concern — the first merged build **did** break: the in-loop `_settleGeneration()` called `_incrementGeneration()` after the final token of the last generation, hit F-01's new bound and reverted the whole `mintWithBudget` call, discarding every token minted in it. The regression suite caught it; the fix is in `fixes/F-04` (break before settling when the last generation is full, refund the remainder), and `fixes/ALL` is re-merged from the corrected patch.

All twelve tests still fail against the merged tree — including the two F-10 tests, which fail because the rollover no longer reverts — and [`test/Regression.t.sol`](test/Regression.t.sol) checks that the normal flows survive:

| Regression test | What it pins down |
|---|---|
| `test_regression_singleMint` | a public mint still works and charges the opening price |
| `test_regression_forgeAtExactFee` | forging at exactly the listed fee still works and still splits 90/10 |
| `test_regression_realForge` | the same, but on the real `TraitForgeNft` + real `EntityForging` with a chosen entropy stream |
| `test_regression_patch_rolloverKeepsPrefillAndPrice` | the rollover keeps the forged pre-fill **and** prices from the new curve starting at that pre-fill (0.0051475 ETH for the 6th entity) |
| `test_regression_patch_budgetMintAcrossBoundary` | a budget mint that crosses 1→2 mints and refunds correctly, and the batch that fills the absolute cap stops instead of reverting |
| `test_regression_patch_burnDebitsCurrentOwner` | burning a transferred token debits the current owner (F-07) |
| `test_regression_patch_pauseStopsMinting` | F-08's pause stops minting and unpause resumes it |
| `test_regression_patch_guards` | F-05/F-09 rejection paths fire instead of trapping or burning funds |
| `test_regression_patch_entropyCallerRole` | F-10 lets the rollover run while the deployer still owns the generator |

```bash
forge test --remappings 'traitforge/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 9 passed
```

On the unpatched sources the six `test_regression_patch_*` tests are reported as skipped (there is no fixed behaviour to regress against yet), so `forge test` stays green on the reviewed commit: 16 passed, 6 skipped.

### Invariant testing

`test/invariant/TraitForgeInvariants.t.sol` drives public mint and budget mint with random actors, amounts and time, and checks three properties after every call sequence:

| Invariant | What it catches |
|---|---|
| `invariant_contractHoldsNoEth` | a mint path that stops forwarding or refunding ETH |
| `invariant_generationStaysWithinCap` | a generation counter that can exceed `maxTokensPerGen` through the public path |
| `invariant_generationWithinMax` | the generation counter passing `maxGeneration` |

```bash
forge test --match-path 'test/invariant/*'
# expect: 3 invariants pass (64 runs x 32 depth, 0 reverts)
```

Both the reviewed sources and `fixes/ALL` pass. **What it does not cover, stated plainly:** forging is not driven by the handler (the light fixture cannot choose the forger/merger pair), so generation accounting under forging is only covered by the PoCs; and `invariant_generationWithinMax` cannot reach the 100,000-mint boundary in a fuzz run, so the missing cap that F-01 reports is still demonstrated by P4, not by the invariant. The suite is a regression net, not a discovery tool.
