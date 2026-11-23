# fixes/ALL — every finding fixed at once

This tree is the union of `fixes/F-01` … `fixes/F-11`, produced by a per-file
three-way merge (`git merge-file`, base = `src/`, one patch at a time). It is
byte-identical to re-running that merge today:

```bash
# from the audit folder, with a scratch copy of src/
# for each F-0x: git merge-file <scratch/file> src/<file> fixes/F-0x/src/<file>
# result must equal fixes/ALL/src/<file>
```

There is no hand edit in this tree: the one interaction bug found so far lives in
F-04 itself (see below), so `ALL` stays a mechanical merge.

## Why it exists

A single-fix tree proves that a PoC is sensitive to *that* change. It cannot show
that ten changes coexist, and it cannot show that the fixes keep the normal flows
working. Two things are run against this tree:

```bash
# every PoC must still fail
forge test --remappings 'traitforge/=fixes/ALL/src/'
# expect: 12 failed, 9 passed (the 9 are the regression suite)

# the normal flows must still work
forge test --remappings 'traitforge/=fixes/ALL/src/' --match-path test/Regression.t.sol
# expect: 9 passed
```

## What the merge caught

The first merged build reverted the whole `mintWithBudget` call when the batch
reached the absolute cap: after the 10,000th token of the last generation the
in-loop `_settleGeneration()` called `_incrementGeneration()`, which hits F-01's
`require(currentGeneration < maxGeneration)`. The regression test reported
`[FAIL: Exceeds max generations]`. The fix is in F-04 (break before settling when
the last generation is full, refund the remainder), and this tree was re-merged
from the corrected patch. `fixes/F-04/NOTES.md` records both corrections.

## Limits

- Not a proposed release: fixes are applied in ID order, with no migration or
  storage-layout review.
- F-10's patch changes `initializeAlphaIndices` to accept the NFT as a caller; the
  deployment procedure in the report (no ownership transfer) is what makes
  F-08's `pause()` reachable.
- The merge is textual. A patch that is semantically wrong but textually clean
  would still merge, which is why `test/Regression.t.sol` exists.
