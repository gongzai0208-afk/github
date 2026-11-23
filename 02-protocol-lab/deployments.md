# Sepolia deployment — 2026-11-23

| Field | Value |
|---|---|
| Network | Sepolia, chain ID `11155111` |
| Deployer | `0x37e6af63B03525e9140bdc09679EaB4EB2ab5a73` |
| Script | `script/DeployTestnet.s.sol` |
| Compiler | solc 0.8.25, optimizer 200, `evm_version = cancun` |
| Broadcast record | `broadcast/DeployTestnet.s.sol/11155111/run-latest.json` |
| Total gas | 39,667,259 |
| Total paid | 0.000000000697430603 ETH |

## Addresses

| Contract | Address | Tx | Block |
|---|---|---|---:|
| MockERC20 (tUSD) | [`0x535C69CC15541F87a0B5e0496F863A6F7B3869b8`](https://sepolia.etherscan.io/address/0x535C69CC15541F87a0B5e0496F863A6F7B3869b8) | `0x36822b4a…d9396` | 12195085 |
| MockERC20 (tWETH) | [`0x745A7e61745A62398F9DeA155feD14483938f1eC`](https://sepolia.etherscan.io/address/0x745A7e61745A62398F9DeA155feD14483938f1eC) | `0xb7a8a633…aab453d` | 12195087 |
| MockFeed | [`0x88B071954C869311BA674F6ea876870Ac84a5949`](https://sepolia.etherscan.io/address/0x88B071954C869311BA674F6ea876870Ac84a5949) | `0x2a6fb157…bf0872` | 12195088 |
| TwapOracle | [`0xE567dB9926b81E486edF81767AbD19F79CB58d2A`](https://sepolia.etherscan.io/address/0xE567dB9926b81E486edF81767AbD19F79CB58d2A) | `0x617cd4b1…788f23` | 12195090 |
| InterestModel | [`0x45894fefCf1e9f152ff21209522F7E4849874270`](https://sepolia.etherscan.io/address/0x45894fefCf1e9f152ff21209522F7E4849874270) | `0xf1dcd6aa…d2a1aad` | 12195095 |
| Timelock | [`0x766f66E14cc918f67508Bd22Fe8b78B1b8b6b2a4`](https://sepolia.etherscan.io/address/0x766f66E14cc918f67508Bd22Fe8b78B1b8b6b2a4) | `0x5d76c9c4…a1589760` | 12195097 |
| LendingPool | [`0x678377b69DbC206F30D40Fba48B21006c750AA35`](https://sepolia.etherscan.io/address/0x678377b69DbC206F30D40Fba48B21006c750AA35) | `0x8cae3c66…d87da3` | 12195099 |

Full transaction hashes:

```
MockERC20 (tUSD)  0x36822b4a0c28764d251bbf2a9ac8d68c5813e692440ddb8a534e2f39e11d9396
MockERC20 (tWETH) 0xb7a8a6336b961d22458104c828a4d60b1bb943bc648ce64e3562a38b3aab453d
MockFeed          0x2a6fb157e5e8c6856a5625a3c8e816cf5296ee1688d2b49243242978e1bf0872
feed.set          0xc4fbb6505c6a4aaa3aa6de1cadb2455c2215f06882f50255fede8d62e475917c
TwapOracle        0x617cd4b13eb6df6d9abbdf491d15f287c63daa9d6b74cd6ad43ae6e1eb788f23
oracle.pushPrice  0x6c1db87127a2d94634cb2e2b56d94118b664436c7822d9b743fb85fbda90c185
InterestModel     0xf1dcd6aaa11bdceccc223f417b49605f4c0e893a308b00618354a4165d2a1aad
Timelock          0x5d76c9c4db33241fac9ccc61eed2daf05eb49b6b205ae04c34fe5db9a1589760
LendingPool       0x8cae3c660752d67d94513e1b5503ecb60c751cb2be664b39073cc51300d87da3
oracle.transferOwnership 0xe0d4d3506b8cb2fe09385b3ea11f49300711190435394f816ddd8f11c194a83f
```

## On-chain self-check (2026-11-23)

| Check | Expected | Observed |
|---|---|---|
| `pool.owner()` | timelock | `0x766f…b2a4` ✅ |
| `oracle.owner()` | timelock | `0x766f…b2a4` ✅ |
| `oracle.feeder()` | deployer | `0x37e6…5a73` ✅ |
| `timelock.delay()` | 86400 | `86400` ✅ |
| `pool.ltv()` | 0.75e18 | `750000000000000000` ✅ |
| `pool.totalAssets()` | 0 | `0` ✅ |
| `oracle.lastPrice()` | 2000e18 | `2000000000000000000000` ✅ |

## Gas model on this chain (important)

Sepolia here charges roughly **1,550 gas per byte** of deployed code, not the 200 that forge's
local EVM assumes. Measured with `cast call --create` binary search:

| Contract | Runtime bytes | Node estimate | Threshold |
|---|---:|---:|---:|
| MockERC20 | 1,543 | 2,851,099 | between 2.70M and 2.85M |
| Timelock | 2,460 | 4,272,068 | — |
| LendingPool | 11,391 | — | 18,821,677 used |

Consequences:

- forge 1.8.5 estimates are 5–8× too low on this chain; the first attempts failed with
  `gasUsed == gasLimit` and status 0.
- Deployment used `--gas-estimate-multiplier 1500 --block-gas-limit 200000000`.
- `--gas-limit` is an alias of `--block-gas-limit`; using it to raise per-tx gas instead caps the
  whole simulated block and fails the script locally.

Reproduce the threshold check:

```bash
cast call --rpc-url $SEPOLIA_RPC_URL --from <deployer> --gas-limit 2850000 --create <initcode>
```

## Seed demo (2026-11-23)

Seven transactions, all successful; total 1,775,644 gas (0.000000000032 ETH).

| Step | Tx | Block |
|---|---|---:|
| tUSD.mint(10,000) | `0x9693ffae…1ed42b` | 12195583 |
| tUSD.approve(pool) | `0xe3943bf1…982883` | 12195583 |
| pool.deposit(10,000) | `0x3628d2c5…69ba9fd` | 12195583 |
| tWETH.mint(5) | `0x157d2e14…9c97cd` | 12195583 |
| tWETH.approve(pool) | `0x4f3df8d2…23eb93` | 12195583 |
| pool.depositCollateral(5) | `0xe6c228b3…339633a2` | 12195584 |
| pool.borrow(5,000) | `0xdcb62cf0…2def63` | 12195584 |

Resulting on-chain state:

| Check | Value |
|---|---|
| `pool.totalAssets()` | `10000000000000000000000` (10,000e18) |
| idle (`tUSD.balanceOf(pool)`) | `5000000000000000000000` |
| `pool.debtOf(deployer)` | `5000000000000000000000` |
| `pool.collateralOf(deployer)` | `5000000000000000000` |
| `pool.balanceOf(deployer)` | `10000000000000000000000000000` |
| `oracle.price()` | `2000000000000000000000` |

A second `SeedDemo` run without `--broadcast` only simulates on top of this state; it does not
change the chain.

## Re-run commands

```powershell
$env:SEPOLIA_RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com"
$env:PRIVATE_KEY = "0x..."

# oracle refresh (feed maxAge is 1h; the TWAP window is 60s in this demo)
forge script script/PokePrice.s.sol `
  --rpc-url $env:SEPOLIA_RPC_URL --broadcast `
  --gas-estimate-multiplier 1500 --block-gas-limit 200000000

# lend 10,000 tUSD, post 5 tWETH, borrow 5,000 tUSD
forge script script/SeedDemo.s.sol `
  --rpc-url $env:SEPOLIA_RPC_URL --broadcast `
  --gas-estimate-multiplier 1500 --block-gas-limit 200000000
```

On a machine where foundry cannot write its global solc cache, add
`--use /path/to/solc-0.8.25` to both commands. The multiplier and block-gas-limit flags are not
optional here: forge underestimates Sepolia gas by 5–8× and the deployment transaction runs out of gas
with the defaults.

## Source verification

`scripts/verify_sepolia.py` submits all seven contracts with their constructor arguments rebuilt from
the deployment script. It talks to the Etherscan v2 API directly and rebuilds the standard-json input
from `out/build-info`, which is why the compiler settings (`0.8.25`, optimizer 200, `cancun`,
`bytecodeHash: none`, `appendCBOR: false`) reproduce exactly.

```powershell
$env:ETHERSCAN_API_KEY = "..."          # or put ETHERSCAN_API_KEY=... in .env (gitignored)
python scripts/verify_sepolia.py        # --cast/--solc when they are not on PATH
python scripts/verify_sepolia.py --status
```

Status: **verified, 2026-11-23**. All seven contracts, verified against the settings above:

| Contract | Address | Etherscan |
|---|---|---|
| tUSD | `0x535C69CC15541F87a0B5e0496F863A6F7B3869b8` | [code](https://sepolia.etherscan.io/address/0x535C69CC15541F87a0B5e0496F863A6F7B3869b8#code) |
| tWETH | `0x745A7e61745A62398F9DeA155feD14483938f1eC` | [code](https://sepolia.etherscan.io/address/0x745A7e61745A62398F9DeA155feD14483938f1eC#code) |
| MockFeed | `0x88B071954C869311BA674F6ea876870Ac84a5949` | [code](https://sepolia.etherscan.io/address/0x88B071954C869311BA674F6ea876870Ac84a5949#code) |
| TwapOracle | `0xE567dB9926b81E486edF81767AbD19F79CB58d2A` | [code](https://sepolia.etherscan.io/address/0xE567dB9926b81E486edF81767AbD19F79CB58d2A#code) |
| InterestModel | `0x45894fefCf1e9f152ff21209522F7E4849874270` | [code](https://sepolia.etherscan.io/address/0x45894fefCf1e9f152ff21209522F7E4849874270#code) |
| Timelock | `0x766f66E14cc918f67508Bd22Fe8b78B1b8b6b2a4` | [code](https://sepolia.etherscan.io/address/0x766f66E14cc918f67508Bd22Fe8b78B1b8b6b2a4#code) |
| LendingPool | `0x678377b69DbC206F30D40Fba48B21006c750AA35` | [code](https://sepolia.etherscan.io/address/0x678377b69DbC206F30D40Fba48B21006c750AA35#code) |

`forge verify-contract` was not used: on the machine this was built on it exits with a file-access error (Windows `os error 5`) before it reaches the network (forge initialises its solc/user-data directory first). The API path removes that dependency and prints the verifier's own error text when something is wrong.

## Demo limitations
- Both tokens are `MockERC20` with a public `mint` — anyone can mint. Demo only.
- The price feed is a `MockFeed`; the oracle's 60-second window is a demo setting, not a
  production parameter.
- The timelock owner is a single EOA. Production would use a multisig.
- Etherscan shows the source, but the deployment is still a demo: mock tokens, mock feed, 60-second
  TWAP window, one EOA in control.
