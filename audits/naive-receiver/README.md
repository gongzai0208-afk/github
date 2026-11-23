# Smart Contract Security Review — NaiveReceiver

**Target:** `src/NaiveReceiverPool.sol`, `src/BasicForwarder.sol`, `src/FlashLoanReceiver.sol`, `src/Multicall.sol`
**Compiler:** solc 0.8.25, OpenZeppelin 5.2.0, Solmate, Solady
**Date:** November 2026

---

## 1. Executive Summary

A WETH pool offering ERC-3156 flash loans, with a meta-transaction forwarder so users can act through a relayer. Two issues are reported, both **High**, and both are theft of funds from parties who did nothing wrong.

| ID | Severity | Title |
|---|---|---|
| F-01 | High | Anyone can initiate a flash loan on behalf of any receiver, forcing the receiver to pay the fee |
| F-02 | High | Sender identity is derived from the calldata tail, letting a relayer user impersonate any depositor |

Both are reproduced in [`test/`](test/); the second one moves 1,000 WETH out of the pool in a single transaction.

## 2. Scope

| File | Lines | SHA-256 |
|---|---|---|
| `src/NaiveReceiverPool.sol` | 93 | `4321f8d50fe23c0eed9b018eb053bce923d845a5a93afed004478f6c50969e28` |
| `src/BasicForwarder.sol` | 104 | `1a851a894c8bf3b1608bab7c42b69418a9111e0b7349c148989ea0e233fca13f` |
| `src/FlashLoanReceiver.sol` | 41 | `752287c8908ba00f49679aed8e9d826122813b42f874f5bc10f8c2a1bfac069c` |
| `src/Multicall.sol` | 16 | `6d7bf6e03ba4f1f3cc9f29b5dd17bfaf9ff1700209a5a09910ebd18b83864d5f` |

These are the challenge contracts distributed with Damn Vulnerable DeFi v4, reproduced here so the proofs can be run without the rest of that repository.

## 3. Severity Classification

The same three definitions are used in all three reviews in this repository:

| Severity | Definition |
|---|---|
| **High** | Loss of user funds, or a broken core invariant, reachable through the documented flow with well-formed input, where neither the victim's own wrong amount nor a privileged role setting an invalid value is required. |
| **Medium** | Bounded or self-inflicted value loss (an overpayment, stranded dust, an overcharge at a generation boundary), economic distortion, or denial of service under normal use. |
| **Low** | Requires a privileged role to set an invalid value first (misconfiguration), a dead safety mechanism, or no direct fund loss. |

Both findings here are High: any account can trigger them, the calls are ordinary, and the loss is other people's funds.

A privileged call still counts as the documented flow when the contract itself validates that input; a wrong value is excluded from High only where the code performs no check on it. Neither finding here depends on a privileged role at all, so that distinction does not arise.

## 4. Findings

### F-01 — Anyone can initiate a flash loan on behalf of any receiver

**Severity:** High
**Location:** `src/NaiveReceiverPool.sol` L43–64

**Description.**
`flashLoan` takes the receiver as a parameter and never checks any relationship between the caller and that receiver:

```solidity
// L43-58
function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
    external
    returns (bool)
{
    if (token != address(weth)) revert UnsupportedCurrency();
    weth.transfer(address(receiver), amount);
    totalDeposits -= amount;
    if (receiver.onFlashLoan(msg.sender, address(weth), amount, FIXED_FEE, data) != CALLBACK_SUCCESS) {
        revert CallbackFailed();
    }
    uint256 amountWithFee = amount + FIXED_FEE;
    weth.transferFrom(address(receiver), address(this), amountWithFee);
```

The fee is fixed at 1 WETH regardless of the borrowed amount, and it is paid by the receiver, not the caller. ERC-3156 does pass the initiator to `onFlashLoan` (the pool passes `msg.sender`), but the pool never requires the caller to have any relationship with the receiver, and a receiver written to the naive pattern — approve and repay, without inspecting the initiator — cannot tell a legitimate request from a hostile one.

**Impact.**
Any contract that holds WETH and implements `onFlashLoan` can be drained by repeatedly opening zero-size loans against it. Each call costs the attacker gas and costs the victim 1 WETH. The victim does not need to have interacted with the pool at all beyond holding a balance.

**Proof of Concept.**
`test_PoC_N01_unprotectedFlashLoanDrainsReceiver` in [`test/NaiveReceiverPoC.t.sol`](test/NaiveReceiverPoC.t.sol). The receiver holds 10 WETH; the attacker holds nothing and calls `flashLoan(receiver, weth, 0, "")` ten times.

Observed: receiver balance 10 → 0, fee receiver's deposit credited with the full 10 WETH, attacker balance still 0. The attack is a loop, not a one-off.

**Recommendation.**
Require consent. The cheapest correct form is to bind the caller to the receiver:

```solidity
if (msg.sender != address(receiver)) revert Unauthorized();
```

If third-party-initiated loans are a product requirement, the receiver must pre-approve the initiator and the pool must pass it through, for example by whitelisting initiators per receiver and checking that mapping before the transfer.

**Cost of this fix, stated explicitly.** Binding to `msg.sender` also rejects a **receiver that initiates its own loan through the forwarder**: the forwarder is then `msg.sender`, not the receiver, so a meta-transaction from the receiver to `flashLoan` fails. The same applies to any router or batching contract acting for the receiver. Receivers that call the pool directly are unaffected; receivers that need meta-transactions need the allowlist form (or a `_msgSender()`-based check), not the one-line guard. The patch in `fixes/F-01/` is the one-line guard, and the regression suite covers the direct-call case (`test_regression_selfInitiatedFlashLoan`).

---

### F-02 — Sender identity is derived from the calldata tail, allowing impersonation

**Severity:** High
**Location:** `src/NaiveReceiverPool.sol` L86–92 (`_msgSender`), interacting with `src/BasicForwarder.sol` L63 and `src/Multicall.sol` L9–16

**Description.**
The pool recovers the "real" sender for meta-transactions by reading the last 20 bytes of calldata:

```solidity
// NaiveReceiverPool.sol L86-92
function _msgSender() internal view override returns (address) {
    if (msg.sender == trustedForwarder && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    } else {
        return super._msgSender();
    }
}
```

The forwarder appends `request.from` to the payload it forwards (`BasicForwarder.sol` L63), which is why the tail is trusted. But `Multicall` executes each sub-call with `Address.functionDelegateCall(address(this), data[i])` — a delegatecall, so `msg.sender` remains the forwarder while `msg.data` is whatever the caller supplied. Inside such a sub-call the author of the data controls the final 20 bytes, and the pool accepts them as the sender.

**Impact.**
Any user who can get a signed request executed through the forwarder — which is the normal way to use this pool — can append an arbitrary address to a `withdraw` call and withdraw that address's deposit. The signature check in the forwarder only authenticates the attacker's own address, which is irrelevant to the impersonated account.

**Proof of Concept.**
`test_PoC_N02_forwarderSpoofStealsVictimDeposit` in [`test/NaiveReceiverPoC.t.sol`](test/NaiveReceiverPoC.t.sol).

Sequence: the victim (deployer) has 1,000 WETH deposited in the pool. The attacker generates a key pair, builds `withdraw(1000e18, attacker)` calldata, appends the victim's address, wraps it as a single `multicall` sub-call, and signs the request as themself. The forwarder verifies the signature against `request.from = attacker` and executes.

Observed: `deposits[victim]` 1,000 → 0, attacker's WETH balance 0 → 1,000, pool balance 0.

**Recommendation.**
Never derive identity from a data suffix that callers can influence. Options, in order of preference:

1. Drop `_msgSender()` and have the forwarder call an explicit-target function where the sender address is a named argument covered by the signature, e.g. `executeFor(address from, ...)` verified with a nonce — the address is then authenticated by the signature, not by byte position.
2. If ERC-2771 style is required, the tail must be trusted only for calldata that arrives **directly** from the forwarder entry point, never for a delegatecall. In a delegatecall `msg.sender` is still the forwarder and `address(this)` is still the pool, so no check inside `_msgSender()` can tell the two apart — the separation has to happen at the entry point: have the forwarder call a dedicated function that sets a one-shot flag for the duration of the call, or make `Multicall` reject payloads whose trailing 20 bytes would be interpreted as a sender.
3. At minimum, verify `msg.data.length == expectedSelectorSize + 20` per function rather than `>= 20`.

## 5. Out of Scope and Limitations

- `FlashLoanReceiver` is the victim fixture, not a production contract; its `onFlashLoan` correctly verifies that the caller is the pool, which is why only the fee can be extracted there.
- The forwarder's signature scheme (EIP-712, nonce, deadline) is otherwise sound and was not broken.
- The F-02 remediation shown in the appendix is verified to stop the attack, but it also disables batched meta-transactions; see the appendix note.
- No fuzzing or invariant campaign; findings come from manual reading plus targeted execution.
- These contracts are a deliberately vulnerable teaching target, reproduced with their original comments removed where irrelevant.
- **Provenance.** Both issues are part of a public Damn Vulnerable DeFi challenge with published solutions, and this folder is a reproduction: the contract is public, the intended answers are public, and the PoCs were written with that context. Nothing here is claimed as an independent discovery, and the two findings being well known means the folder is evidence of the verification chain (state assertions, per-patch failure, merged-tree regression), not of discovery.
- **Not covered.** Only the two issues above were examined; the rest of the challenge's contract behaviour was not reviewed in depth.

## 6. Appendix

```bash
forge test -vv
```

| Test | Finding | Fails when fixed? |
|---|---|---|
| `test_PoC_N01_unprotectedFlashLoanDrainsReceiver` | F-01 | **yes** — `fixes/F-01/` adds `msg.sender == receiver`, PoC reverts with `Unauthorized()` |
| `test_PoC_N02_forwarderSpoofStealsVictimDeposit` | F-02 | **yes** — `fixes/F-02/` rejects forwarder-originated `multicall`, victim deposit stays 1,000 WETH |

Cost of the F-02 fix, stated explicitly: rejecting forwarder-originated `multicall` also removes batched meta-transactions. That is inherent — a delegatecall's calldata tail cannot be authenticated from inside `_msgSender()` — so the choice is between batching and a spoofable sender, not a free fix.

### Combined patch

`fixes/ALL/src/` merges both fixes (they touch different files — `NaiveReceiverPool.flashLoan` and the `multicall` override — so the merge is conflict-free). Both PoCs still fail against it (`logs/all-poc-fail.txt`), and [`test/Regression.t.sol`](test/Regression.t.sol) checks what must keep working: a receiver that initiates its own flash loan is still served, deposit/withdraw round-trips, a **single** forwarded call still authenticates `request.from`, and the spoofed multicall is rejected with the victim's deposit intact.

```bash
forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 4 passed
```

### Invariant testing

`test/invariant/NaiveReceiverInvariants.t.sol` drives `deposit`, `withdraw` and a receiver-initiated `flashLoan` with random actors and amounts:

| Invariant | What it catches |
|---|---|
| `invariant_totalDepositsMatchesSum` | the aggregate deposit counter drifting from the per-user entries |
| `invariant_poolHoldsWhatItOwes` | the pool's WETH balance diverging from the deposits it owes |

```bash
forge test --match-path 'test/invariant/*'
# expect: 2 invariants pass (64 runs x 32 depth, 0 reverts)
```

Both the reviewed sources and `fixes/ALL` pass. The suite does not exercise the forwarder path (that is F-02's PoC), and it does not attempt third-party-initiated loans, because the F-01 fix rejects them by design.
