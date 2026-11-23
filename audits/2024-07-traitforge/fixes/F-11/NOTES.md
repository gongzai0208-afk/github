# F-11 patch — `taxCut` is a percentage, not a divisor

Patched tree: `fixes/F-11/src/` — a full copy of `src/`. Three files differ:
`EntityForging`, `EntityTrading`, `NukeFund`.

## Strategy

`taxCut` defaults to `10` and is documented as "10%", but every consumer divides
by it. `x / 10` is only equal to `x × 10%` because `10 == 100/10`; any other value
silently mis-splits, and `0` reverts on the division in all three contracts.

The patch multiplies instead, and bounds the three setters:

```solidity
// EntityForging.sol L146, EntityTrading.sol L72, NukeFund.sol L41
uint256 devFee = (forgingFee * taxCut) / 100;

// in all three setTaxCut functions
require(_taxCut > 0 && _taxCut <= 100, 'Invalid tax cut');
```

## Command and observed output

```bash
forge test --remappings 'traitforge/=fixes/F-11/src/' --match-test test_PoC_P12
# expect: [FAIL: 5% cut is applied as a divisor: the treasury takes 20%: 50000000000000000 != 200000000000000000]
```

The PoC asserts the mis-split (0.2 ETH to the treasury at a 5% cut); against this
tree the treasury receives 0.05 and the assertion fails.

## Notes / limits

- **This is the published H-03, rated High there and Low here.** The difference is
  in the trigger, not the arithmetic: only the owner can change `taxCut`, and at the
  deployed value of `10` the split is correct. Under the report's definitions a
  privileged role setting an invalid value is Low. The rating difference is listed
  in the report's §5 table.
- A zero cut is a division-by-zero revert in `EntityForging.forgeWithListed`,
  `EntityTrading`'s sale path and `NukeFund`'s receive path — three separate
  contracts share the same mistake, which is why the patch touches all three.
- The bound `_taxCut <= 100` is a policy choice (a "cut" above 100% would invert
  the split); the original code had no bound at all. If the product wants to allow
  a cut of 0 to mean "no fee", the setter should convert it to an explicit flag
  rather than leaving the division in place.
- `taxCut` is read at use time, so the patch changes behaviour for future calls
  only; a deployed contract with a bad value still needs the owner to call the
  setter again after upgrading.
