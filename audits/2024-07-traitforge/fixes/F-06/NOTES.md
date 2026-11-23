# F-06 patch

- File: `EntityForging/EntityForging.sol`
- Change: strict comparison, matching the post-increment check on the merger side

Verify:

```bash
forge test --remappings 'traitforge/=fixes/F-06/src/' --match-test <PoC name>
```
