# F-02 patch

- File: `TraitForgeNft/TraitForgeNft.sol`
- Change: loop guard now bounds by the per-generation counter, matching the cap it is meant to enforce

Verify:

```bash
forge test --remappings 'traitforge/=fixes/F-02/src/' --match-test <PoC name>
```
