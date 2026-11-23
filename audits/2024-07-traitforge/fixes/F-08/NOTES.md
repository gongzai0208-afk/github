# F-08 patch

The finding covers all six contracts. This tree adds `pause()` / `unpause()` (onlyOwner) to all six,
not just `TraitForgeNft`, which is the only one the PoC exercises.

```bash
forge test --remappings 'traitforge/=fixes/F-08/src/' --match-test test_PoC_P8
# expect: [FAIL: pause() is reachable from outside]
```

## Notes / limits

- **`EntropyGenerator.pause()` is unreachable under the deployment this report
  requires.** F-10 establishes that `EntropyGenerator` ownership must be handed to
  `TraitForgeNft` for the rollover to work (or, with the F-10 patch, that it should
  keep a human owner and grant the NFT a caller role). Without the F-10 patch the
  owner of the generator is a contract with no forwarding path, so the `pause()`
  added here to `EntropyGenerator` can never be called. The other five contracts
  keep a human owner and the pause is reachable there. Read F-08 and F-10
  together: F-08 supplies the entry point, F-10 is what makes it callable.
- The PoC (`P8`) only exercises `TraitForgeNft`; the other five entries are a
  reading-level claim, as the report states.
