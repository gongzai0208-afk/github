# Samples

`Dispatcher.sol` is the only input. `Dispatcher.bin` is its runtime bytecode, committed as hex text
so it can be read and diffed; every `evmlab` command accepts either hex text or raw bytes.

Rebuild it with solc 0.8.25:

```bash
solc --evm-version cancun --optimize --optimize-runs 200 --bin-runtime \
     -o build samples/Dispatcher.sol
mv build/Dispatcher.bin-runtime samples/Dispatcher.bin
```

The contract has three callable functions and three public getters, two of the callables behind an
`msg.sender == owner` guard and one unguarded, so the entry table has something to get wrong:

| selector | signature | what the table should say |
|---|---|---|
| `0x55241077` | `setValue(uint256)` | caller guard, one storage write |
| `0xff9913e8` | `allow(address)` | caller guard, one storage write, five revert sites |
| `0x18178358` | `poke()` | no guard, read-modify-write |
| `0x8da5cb5b` | `owner()` | no guard, one read |
| `0x3fa4f245` | `value()` | no guard, one read |
| `0xd63a8e11` | `allowed(address)` | no guard, one read |

This replaced an earlier sample set taken from a private engagement. Those binaries are third-party
code and are not redistributed here; the aggregate numbers from that engagement are quoted in the
track README, the files are not.
