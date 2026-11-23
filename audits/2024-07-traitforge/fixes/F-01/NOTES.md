# F-01 patch — bound the generation counter

`_incrementGeneration()` gets the missing `require(currentGeneration < maxGeneration, "Exceeds max generations")`.
The check already existed in `forge()` (L166); it now lives where the state actually changes.

**Does the fixed state still have a hole?** No new authority or external call. The only behaviour change is
that a mint which would have rolled past generation 10 now reverts instead of succeeding.

```bash
forge test --remappings 'traitforge/=fixes/F-01/src/' --match-test test_PoC_P4
# expect: [FAIL: Exceeds max generations]
```
