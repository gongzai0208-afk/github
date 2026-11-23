# F-09 patch

Zero-address guard added to **both** setters named in the report:
`TraitForgeNft.setNukeFundContract` and `EntityForging.setNukeFundAddress`.

```bash
forge test --remappings 'traitforge/=fixes/F-09/src/' --match-test test_PoC_P9
# expect: [FAIL: Zero address]
```
