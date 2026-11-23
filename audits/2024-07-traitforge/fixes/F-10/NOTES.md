# fixes/F-10 — TraitForge F-10: generation rollover requires ownership, and ownership removes the admin

Patched tree: `fixes/F-10/src/` — a full copy of `src/`. Only
`EntropyGenerator/EntropyGenerator.sol` differs.

## Strategy

`TraitForgeNft._incrementGeneration()` calls `initializeAlphaIndices()`, which is
`onlyOwner`. The NFT is not the owner, so the rollover reverts unless the deployer
transfers ownership — and then no external account can call any `onlyOwner`
function on the generator again.

The fix gives the NFT a *caller role* instead of ownership. `allowedCaller` is
already set to the NFT in the constructor (`L30-33`), so nothing new is needed:

```solidity
modifier onlyOwnerOrAllowedCaller() {
  require(
    msg.sender == owner() || msg.sender == allowedCaller,
    'Caller is not allowed'
  );
  _;
}

function initializeAlphaIndices() public whenNotPaused onlyOwnerOrAllowedCaller { ... }
```

The owner keeps `setAllowedCaller`, and the `pause()` added by F-08 stays
reachable. The deployment procedure no longer transfers ownership.

## Command and observed output

```bash
forge test --remappings 'traitforge/=fixes/F-10/src/' --match-test test_PoC_P10
# expect: [FAIL: next call did not revert as expected]

forge test --remappings 'traitforge/=fixes/F-10/src/' --match-test test_PoC_P11
# expect: [FAIL: next call did not revert as expected]
```

## Notes / limits

- Both PoCs fail on the same step: the rollover-triggering mint no longer reverts.
  P10 stops there; P11 asserts the DoS first and then the administrative loss, so
  under the fix it also stops at the first leg. The second leg is therefore not
  re-measured on this tree — it is a property of `Ownable` (only the owner can
  call owner-only functions), not of the patch.
- The patch does not prevent a deployer from transferring ownership voluntarily.
  It removes the *need* to.
- If the product wants the NFT to be the only caller forever, `allowedCaller`
  should not be rotatable at all; the patch keeps it rotatable by the owner, which
  is the safer default when the NFT itself might be replaced.
