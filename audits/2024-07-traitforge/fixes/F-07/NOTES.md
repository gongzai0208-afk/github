# F-07 patch

- File: `TraitForgeNft/TraitForgeNft.sol`
- Change: debit follows the current owner rather than the first minter

Verify:

```bash
forge test --remappings 'traitforge/=fixes/F-07/src/' --match-test <PoC name>
```
