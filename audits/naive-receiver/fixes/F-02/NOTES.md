# fixes/F-02 — NaiveReceiver F-02: sender identity taken from the calldata tail

Patched tree: `fixes/F-02/src/` — a full copy of `src/` (4 contracts). Only
`NaiveReceiverPool.sol` differs; the original `src/` and `test/` are untouched.

## Strategy

Fix at the **entry point**, not inside `_msgSender()`. The last 20 bytes of calldata are
only trustworthy when the call arrives directly from `BasicForwarder` (it appends
`request.from` there). A `Multicall` sub-call is a `delegatecall`, so `msg.sender` is still
the forwarder while `msg.data` is the attacker's payload — inside `_msgSender()` the two
cases are byte-for-byte indistinguishable, which is why no check there can separate them.

So the pool overrides `multicall` and rejects any `multicall` call that comes from
`trustedForwarder`. A forwarder-originated multicall payload is exactly the case where a
caller-supplied tail would be read as a sender; direct multicall (where `msg.sender` is the
caller itself and no tail is trusted) keeps working unchanged.

## Changed lines (patched file)

- L7 — `import {Address} from "@openzeppelin/contracts/utils/Address.sol";`
- L26 — new error `error Unauthorized();`
- L88–104 — new override, placed before `_msgSender`:

```solidity
/// @dev F-02 fix: ...
function multicall(bytes[] calldata data) external override returns (bytes[] memory results) {
    if (msg.sender == trustedForwarder) revert Unauthorized();

    results = new bytes[](data.length);
    for (uint256 i = 0; i < data.length; i++) {
        results[i] = Address.functionDelegateCall(address(this), data[i]);
    }
}
```

`_msgSender()` itself (L106–112) is unchanged — it now only ever sees direct
forwarder calls, whose tail the forwarder controls.

## Command and observed output

Run from the `naive-receiver` folder:

```bash
forge test --remappings 'pool/=fixes/F-02/src/' --match-test test_PoC_N02_forwarderSpoofStealsVictimDeposit -vv
```

```
[FAIL: invariant broken: victim deposit cleared: 1000000000000000000000 != 0] test_PoC_N02_forwarderSpoofStealsVictimDeposit() (gas: 160295)
Logs:
  deposits[victim] after   : 1000000000000000000000
  WETH balance attacker    : 0
  WETH balance pool        : 1000000000000000000000
Suite result: FAILED. 0 passed; 1 failed; 0 skipped
```

PoC now **FAILS** (was PASS): the impersonated `withdraw` never executes. The forwarder
still verifies and runs the attacker's own signed request, but the nested `multicall`
reverts with `Unauthorized()`, `BasicForwarder.execute` swallows the inner failure in its
`success` return value, and the victim's 1,000 WETH deposit is intact.

Full suite on this tree (the F-01 PoC is untouched and still passes, so the two fixes are
independent):

```
[PASS] test_PoC_N01_unprotectedFlashLoanDrainsReceiver()
[FAIL: invariant broken: victim deposit cleared: 1000000000000000000000 != 0] test_PoC_N02_forwarderSpoofStealsVictimDeposit()
Suite result: FAILED. 1 passed; 1 failed
```

## Notes / limits

- Trade-off: meta-transaction users lose batched calls through the forwarder. Given that the
  sender identity of a sub-call cannot be authenticated from the payload, rejecting is the
  safe direction; supporting it properly needs an explicit `executeFor(address from, ...)`
  entry point whose `from` is covered by the request signature (README option 1).
- Single (non-multicall) forwarded calls are unaffected and still authenticate `request.from`
  via the tail the forwarder appends.
