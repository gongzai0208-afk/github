# StakingRewards F-03 patch (standalone)

`exit()` withdraws only when there is a balance, then always claims.
This tree exists so F-03 has its own fix-fail rather than borrowing the F-02 tree.

```bash
forge test --remappings 'pool/=fixes/F-03/src/' --match-test test_PoC_exitRevertsWithoutStake
# expect: [FAIL: next call did not revert as expected]
```
