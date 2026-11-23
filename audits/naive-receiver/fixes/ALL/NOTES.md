# fixes/ALL — every finding fixed at once

This tree is the union of `fixes/F-01` and `fixes/F-02`, produced by a per-file
three-way merge (base = `src/`). The two patches touch different parts of the
same file — the `flashLoan` entry point and the `multicall` override — so the
merge is clean and this tree is byte-identical to re-running it.

## How to run it

```bash
forge test --remappings 'pool/=fixes/ALL/src/'
# expect: 2 failed, 4 passed (the 4 are the regression suite)

forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 4 passed
```

The regression suite is what makes the two costs explicit in executable form:

- `test_regression_selfInitiatedFlashLoan` — a receiver calling the pool directly
  is still served (the F-01 guard only rejects third-party initiators).
- `test_regression_forwardedSingleCall` — single forwarded calls still
  authenticate `request.from` through the tail; F-02 only rejects
  forwarder-originated `multicall`.
- `test_regression_patch_spoofedMulticallRejected` — the attack path is closed and
  the victim's deposit is intact.

## Limits

- Not a proposed release: no migration, no storage-layout review.
- The F-01 guard rejects a receiver that initiates its own loan **through the
  forwarder** (`msg.sender` is then the forwarder). Receivers that need
  meta-transactions need the allowlist form instead; the report states this.
- The F-02 patch removes batched meta-transactions. That is inherent to the
  fix, not an oversight; see `fixes/F-02/NOTES.md`.
