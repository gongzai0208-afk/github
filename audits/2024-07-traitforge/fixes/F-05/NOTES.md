# F-05 patch

- File: `EntityForging/EntityForging.sol`
- Change: exact payment required, so nothing can be left behind

Verify:

```bash
forge test --remappings 'traitforge/=fixes/F-05/src/' --match-test <PoC name>
```
