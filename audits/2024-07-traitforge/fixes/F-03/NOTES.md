# F-03 patch — stop erasing the forged pre-fill

`_incrementGeneration()` no longer sets `generationMintCounts[currentGeneration] = 0` after incrementing.
The counter written by `_mintNewEntity` for a future generation survives the rollover, so the
per-generation cap accounts for entities that were already forged into it.

**Two fixes were possible; this tree uses the second one.**

1. Reject forging into a future generation (`require(gen == currentGeneration)`). This aborts the PoC's
   setup, because the PoC forges into generation 2 while the current generation is 1 — it would fail for
   the wrong reason.
2. Keep the counter. This is the variant under which the PoC fails on its assertion, which is what a
   fix-fail check should look like.

**Does the fixed state still have a hole?** Rejecting the rollover reset means a generation's capacity is
consumed by forged entities as well — which is the intended accounting. The other symptoms of the original
bug (price restart on rollover) are unchanged, but they belong to F-04.

```bash
forge test --remappings 'traitforge/=fixes/F-03/src/' --match-test test_PoC_P3
# expect: [FAIL: generationMintCounts[2] was reset, erasing N entities (correct value is N+1): 9 != 1]
```
