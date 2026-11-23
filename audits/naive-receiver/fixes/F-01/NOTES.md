# fixes/F-01 — NaiveReceiver F-01: anyone can initiate a flash loan on behalf of any receiver

Patched tree: `fixes/F-01/src/` — a full copy of `src/` (4 contracts). Only
`NaiveReceiverPool.sol` differs; the original `src/` and `test/` are untouched.

## Strategy

Bind the initiator to the receiver at the entry point: the fee is paid by the receiver, so
the receiver itself must be the caller. This is the recommendation in README §3 F-01
(`if (msg.sender != address(receiver)) revert Unauthorized();`).

## Changed lines (patched file)

- L25 — new error `error Unauthorized();`
- L50–53 — new guard at the top of `flashLoan`, after the token check and before any
  transfer / `onFlashLoan` callback / fee accounting:

```solidity
// F-01 fix: the fee is paid by the receiver, so the receiver (or someone it
// has authorised) must be the initiator. ...
if (msg.sender != address(receiver)) revert Unauthorized();
```

No other function changed.

## Command and observed output

Run from the `naive-receiver` folder:

```bash
forge test --remappings 'pool/=fixes/F-01/src/' --match-test test_PoC_N01_unprotectedFlashLoanDrainsReceiver -vv
```

```
[FAIL: Unauthorized()] test_PoC_N01_unprotectedFlashLoanDrainsReceiver() (gas: 59846)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped
```

PoC now **FAILS** (was PASS): the attacker's first `flashLoan(receiver, weth, 0, "")` reverts
before any WETH moves, so the receiver is never drained.

Full suite on this tree (the F-02 PoC is untouched and still passes, so the two fixes are
independent):

```
[FAIL: Unauthorized()] test_PoC_N01_unprotectedFlashLoanDrainsReceiver()
[PASS] test_PoC_N02_forwarderSpoofStealsVictimDeposit()
Suite result: FAILED. 1 passed; 1 failed
```

## Notes / limits

- This forbids third-party-initiated loans entirely. If the product needs them, the pool
  would have to carry a per-receiver initiator allowlist checked before the transfer; the
  simple form above is the conservative fix.
- The guard is placed before `weth.transfer` and before `onFlashLoan`, so a rejected call
  cannot even force the receiver's callback to run.
