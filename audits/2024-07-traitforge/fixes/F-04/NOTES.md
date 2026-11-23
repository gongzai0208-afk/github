# F-04 patch — roll into the next generation before pricing

`mintToken` and `mintWithBudget` now call `_settleGeneration()` **before** `calculateMintPrice()`,
and `mintWithBudget` calls it again after each mint. The token is therefore priced in the generation
it actually joins.

**Replaced patch.** The first version only recomputed the price inside `_mintInternal`. `mintToken`
still refunded against the old price, so the buyer kept paying 0.25 ETH while the treasury received
0.005 — the 0.245 difference stayed in the contract. The PoC asserted only the treasury receipt, so
that half-fix looked like a pass. The PoC now asserts the buyer's net spend, which is the harm.

**Second correction, found by merging the patches.** The in-loop `_settleGeneration()` reverted the
whole batch as soon as the batch filled the **last** generation: after the final mint the counter
equals `maxTokensPerGen`, so the settle called `_incrementGeneration()`, which — once F-01's
`require(currentGeneration < maxGeneration)` is applied — reverts, throwing away every token minted
in that call. The loop now breaks before settling when the last generation is full, and the leftover
budget is refunded. This only appears when F-01 and F-04 are applied together, which is exactly what
`fixes/ALL` exists to catch; `test/Regression.t.sol::test_regression_patch_budgetMintAcrossBoundary`
covers both the 1→2 boundary and the last-generation cap.

**Side effect introduced by the pre-loop settle, documented rather than fixed.** `mintWithBudget`
now calls `_settleGeneration()` before checking the budget, so a call with `msg.value == 0` made
while a generation is full completes the rollover (and re-selects the alpha indices) without
minting anything. The caller therefore chooses the block at which the entropy indices are drawn.
It is one rollover per generation, the same block is also selectable by minting one token, and no
funds move, so it is a low-impact side channel rather than a new finding — but it is a consequence
of this patch and is disclosed here instead of being left implicit.

**Does the fixed state still have a hole?**

- `mintToken` refunds `msg.value - mintPrice` after the rollover, so the buyer pays the new price.
- `mintWithBudget` re-settles between iterations, so a batch that crosses a boundary is priced
  correctly for each token; a batch that reaches the absolute cap mints up to it and refunds the rest.
  A batch started **after** the cap is reached reverts (`Exceeds max generations`), matching what a
  single mint does; it does not accept ETH and silently refund.
- No new external call or authority is added; `_settleGeneration` only calls the existing private
  `_incrementGeneration`.

## Verify

```bash
forge test --remappings 'traitforge/=fixes/F-04/src/' --match-test test_PoC_P6
# expect: [FAIL: buyer net spend is the maxed-out generation-1 price: 5000000000000000 != 250000000000000000]
```

The two failure texts this tree has seen are worth remembering: the first patch produced
`0.005 != 0.25` (half-fix, PoC too weak) and the merge produced `Exceeds max generations`
(interaction bug, no test covered it).
