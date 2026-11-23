# 智能合约安全审计报告 —— TraitForge NFT 系统

**审查对象：** `279b2887e3d38bc219a05d332cbcb0655b2dc644`
**代码库：** `code-423n4/2024-07-traitforge`
**范围：** 6 个合约，880 行 Solidity
**日期：** 2026 年 11 月

---

## 一、摘要

本次审查覆盖 TraitForge NFT 系统：一个带世代铸造机制的 ERC-721 合集，外加实体锻造（forge）、二级市场、链上熵生成器，以及在被销毁时为持有者分红的金库（NukeFund）。

审查方式是逐行人工阅读，配合 Foundry 攻击复现测试。**共报告 11 个问题：2 个高危、6 个中危、3 个低危。** 两条高危与 F-10（中危）都有 PoC 在**真实接线**上复现；11 条结论对应 12 个测试（F-10 有两个，但 P11 与 P10 停在同一处，只算佐证），全部在修复版上失败（11/11 条独立证据，见附录）。测试在 [`test/`](test/) 目录，一条命令可复现。

| 编号 | 严重度 | 标题 |
|---|---|---|
| F-01 | 高危 | 世代上限从未生效，供应量可以无限增长 |
| F-02 | 中危 | 累计铸造达 1 万后，批量铸造永久失效 |
| F-03 | 高危 | 换代清零会抹掉已锻造的预填计数，使单代突破上限 |
| F-04 | 中危 | 价格在换代前计算，每一代的首次铸造都被多收费 |
| F-05 | 中危 | 锻造超额付款永久锁死在合约里 |
| F-06 | 中危 | 锻造者实际可被使用「上限 + 1」次 |
| F-07 | 中危 | 销毁 NFT 扣的是最初铸造者的空投额度，不是当前持有者的 |
| F-08 | 低危 | 所有合约的暂停机制都无法触达 |
| F-09 | 低危 | 金库地址可被设为 `address(0)`，铸造款被静默销毁 |
| F-10 | 中危 | 换代要求熵生成器的所有权，而转移所有权会让管理角色消失 |
| F-11 | 低危 | `taxCut` 被当作除数使用：只要不是 10，三处费率都会算错；设为 0 会让三个合约直接不可用 |

这批问题的共同点不是"攻击手法刁钻"，而是**状态记账前后不一致**：循环边界用了全局计数器而不是每代计数器；换代时把计数清零，而另一个函数可能已经写过这个计数；价格在换代的下一步才变。它们往往只隔几行代码，但每一个都能算出具体金额。

---

## 二、范围

| 文件 | 行数 | git blob SHA-1 |
|---|---|---|
| `contracts/TraitForgeNft/TraitForgeNft.sol` | 396 | `a17de61b961e7289d15aaf775e949dc52dc9c31a` |
| `contracts/EntityForging/EntityForging.sol` | 208 | `c9ce23b70f6eb7543408134d2efe15800b7cbc85` |
| `contracts/EntropyGenerator/EntropyGenerator.sol` | 217 | `3c10979ebe4fa3dc1605e4880c4c65706b4e3913` |
| `contracts/NukeFund/NukeFund.sol` | 195 | `953d7cfed586c3879a68444b5aabc3bcea1a5f46` |
| `contracts/EntityTrading/EntityTrading.sol` | 118 | `57a6b079a486f553f66e199157b6e4f2ee469389` |
| `contracts/DevFund/DevFund.sol` | 93 | `671b578159072af86aee6f4847723fa62e3a0323` |

**编译器：** solc 0.8.25（六个文件均为 `pragma solidity ^0.8.20`）。
**依赖：** OpenZeppelin Contracts v4.9.3（`Pausable`、`ReentrancyGuard`、`Ownable`、ERC-721 扩展、`MerkleProof`），版本由项目 `package.json` 精确锁定。

外部 `Airdrop` 实现只能通过 `IAirdrop` 接口访问，**不在本次范围内**。凡是依赖其行为的结论，都会明确写出。

---

## 三、严重度定义

| 级别 | 判定标准 |
|---|---|
| **高危** | 用户资金损失或核心不变式被破坏，且可通过文档化的流程、以合法输入触发；既不需要受害者自己填错金额，也不需要特权角色先设一个非法值。 |
| **中危** | 有界或自身造成的价值损失（多付、滞留、换代边界多收费）、经济扭曲，或正常使用下的拒绝服务。 |
| **低危** | 需要特权角色先设一个非法值（配置错误）、失效的安全机制，或没有直接资金损失。 |

特权调用如果本身经过合约自己的校验，仍算「文档化流程」；只有当代码对该输入完全没有校验时，错误值才被排除在 High 之外。这就是「owner 调用撞上一个写错的校验」（StakingRewards F-01）与「owner 设了一个没人校验的非法值」（本报告的 F-09、F-11）的区别。

---

## 四、问题详情

### F-01 —— 世代上限从未生效

**严重度：** 高危
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— `_incrementGeneration()` 位于 L345–355；对比 `forge()` 中的检查位于 L166

**描述。**
`maxGeneration` 声明为 `10`（L35），但唯一检查它的地方是锻造路径：

```solidity
// TraitForgeNft.sol:166
require(newGeneration <= maxGeneration, "Exceeds max generations");
```

真正推进世代的函数没有这个检查：

```solidity
// TraitForgeNft.sol:345-355
function _incrementGeneration() private {
  require(generationMintCounts[currentGeneration] >= maxTokensPerGen, 'Generation limit not yet reached');
  currentGeneration++;
  generationMintCounts[currentGeneration] = 0;
  priceIncrement = priceIncrement + priceIncrementByGen;
  entropyGenerator.initializeAlphaIndices();
  emit GenerationIncremented(currentGeneration);
}
```

而 `_mintInternal`（L280–283）在当前代满额后会无条件调用它。因此公开铸造会直接越过上限。

**影响。**
宣传中的 10 × 10,000 = 100,000 枚上限并不存在，铸造会按当前价格曲线无限继续。任何依赖稀缺性的设计——空投总量、链下供应量记账、代币经济模型——都会失效。

**复现。**
[`test/TraitForgeNftPoC.t.sol`](test/TraitForgeNftPoC.t.sol) 中的 `test_PoC_P4_generationExceedsMaxGeneration`。把状态置于边界（`currentGeneration = 10`、`generationMintCounts[10] = 10000`），执行一次公开铸造。

观测结果：铸造成功，`currentGeneration` 变为 **11**，新 token 记在第 11 代。若检查存在，该调用应当 revert。

**修复建议。**
把边界检查放到状态改变的地方，而不是只放在锻造路径：

```solidity
function _incrementGeneration() private {
  require(currentGeneration < maxGeneration, "Exceeds max generations");
  ...
}
```

达到上限时应当 revert，而不是静默推进。

---

### F-02 —— 累计铸造达 1 万后，批量铸造永久失效

**严重度：** 中危（没有资金损失：调用会全额退款，单枚铸造仍可用；坏掉的是批量路径）
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— 循环条件 L215；每代上限 L281；全局计数自增 L285 与 L321

**描述。**
`mintWithBudget` 的循环条件用了一个**全局**计数器去比一个**每代**上限：

```solidity
// TraitForgeNft.sol:215
while (budgetLeft >= mintPrice && _tokenIds < maxTokensPerGen) {
```

`_tokenIds` 跨世代单调递增（L285），锻造路径也会让它自增（L321）。`maxTokensPerGen` 为 10,000。因此只要合约历史上创建过 10,000 枚 token——无论是铸造、锻造还是两者混合——这个条件就永久为假，循环体再也不会执行。

**影响。**
从此以后 `mintWithBudget` 收下用户的 ETH、一枚都不铸、然后全额退款：在合约剩余生命周期里，它就是个只烧 gas 的空操作，尽管第 2 代及以后仍可单枚铸造。任何依赖批量铸造的集成或前端都会静默失效。

**复现。**
`test_PoC_P2_mintWithBudgetDeadAfterMaxSupply`。先做对照：0.05 ETH 铸出 9 枚；然后把 `_tokenIds` 置为 10,000，再发送 1 ETH。

观测结果：铸出 **0** 枚，`totalSupply` 保持 9，调用者 ETH 净变化为 **0**（全额退款），合约余额为 0。

**修复建议。**
用上限真正约束的那个量作为循环条件：

```solidity
while (budgetLeft >= mintPrice && generationMintCounts[currentGeneration] < maxTokensPerGen) {
```

或者按当前代剩余容量拆分循环。

---

### F-03 —— 换代清零抹掉已锻造的预填计数，使单代突破上限

**严重度：** 高危
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— 清零 L350–351；对未来的世代写入 L311–343；锻造路径传入的世代参数 L163

**描述。**
`_incrementGeneration` 会无条件把刚进入的那一代的计数清零：

```solidity
// TraitForgeNft.sol:350-351
currentGeneration++;
generationMintCounts[currentGeneration] = 0;
```

但 `_mintNewEntity` 接受任意 `gen` 参数并自增 `generationMintCounts[gen]`（L328）。锻造路径传入 `gen = 父代 + 1`（L163），因此实体可以被锻造进一个尚未开始的世代。等这一代真正开始时，这些计数被丢弃。

**影响。**
两个后果，都是经济性的。第一，每代上限会被预填实体数量精确突破——它们不占用用于执行上限的那个计数器。第二，新一代的价格曲线会当作什么都没发生过重新开始，导致后续 token 定价偏低。

**复现。**
`test_PoC_P3_generationCountWipedOnRollover`。状态：`currentGeneration = 1`、`generationMintCounts[1] = 10000`、`generationMintCounts[2] = 42`（已有 42 个实体被锻造进第 2 代）。一次公开铸造触发换代。

观测结果：换代后 `generationMintCounts[2] == 1` —— 42 个预填被清零，只有这次新铸造被计入。第 2 代剩余容量是 9,999，而按设计应为 9,957。修复后的实现应当报告 43。

**修复建议。**
不要把可能已被其他路径写过的计数器清零。二选一：

- 拒绝锻造进尚未开始的世代（`require(gen == currentGeneration)`）；
- 或不再清零，从部署起就以 `generationMintCounts[currentGeneration]` 为准。

---

### F-04 —— 价格在换代前计算，每代首次铸造都被多收费

**严重度：** 中危
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— 读价 L190；`_mintInternal` 内换代 L281–283；价格公式 L227–232

**描述。**
`mintToken` 在执行铸造之前先读价格：

```solidity
// TraitForgeNft.sol:190-193
uint256 mintPrice = calculateMintPrice();
...
_mintInternal(msg.sender, mintPrice);
```

而 `_mintInternal` 可能先推进世代（L281–283），再往**新**世代里铸造。此时收取的是**旧**世代的最后一档价格，也就是那一代的最高价。

**影响。**
每一代的边界铸造都会被多收费。以现行常量计，第 1 代收尾价是 `0.005 + 0.0000245 × 10000 = 0.25 ETH`，而第 2 代首枚本应只要 `0.005 ETH`。用户为每代的一枚 token 多付 50 倍，多出的钱进的是金库而不是退回。

**复现。**
`test_PoC_P6_priceOverchargeAtGenerationRollover`。状态：`currentGeneration = 1`、`generationMintCounts[1] = 10000`。

观测结果：收取 0.25 ETH 并转给金库，但 token 实际铸进第 2 代，其正确首价是 0.005 ETH。多收 **0.245 ETH**。换代后 `priceIncrement` 变为 0.0000295 ETH，说明换代发生在定价之后。

**修复建议。**
把定价移到换代判定之后：

```solidity
if (generationMintCounts[currentGeneration] >= maxTokensPerGen) _incrementGeneration();
uint256 mintPrice = calculateMintPrice();
```

---

### F-05 —— 锻造超额付款永久锁死在合约里

**严重度：** 中危
**位置：** `contracts/EntityForging/EntityForging.sol` —— 收费检查 L126；分配 L146–159

**描述。**
函数接受任何不低于手续费的付款：

```solidity
// EntityForging.sol:126
require(msg.value >= forgingFee, 'Insufficient fee for forging');
```

但只分配手续费本身：

```solidity
// EntityForging.sol:146-147
uint256 devFee = forgingFee / taxCut;
uint256 forgerShare = forgingFee - devFee;
```

合约里没有 `receive`、没有 `fallback`、没有提现或救援函数。高于 `forgingFee` 的部分永久留在合约余额里。

**影响。**
用户资金不可挽回地锁死。触发条件很普通：钱包或集成方发送了取整金额、挂单与执行之间费率被下调、或者用旧报价重试——都会产生一笔滞留余额。过程中没有报错、没有事件、也没有退款路径。

**复现。**
`test_PoC_P1_excessPaymentLocked`。挂单手续费 1 ETH，合并方发送 3 ETH。

观测结果：锻造者所有者收到 0.9 ETH，金库收到 0.1 ETH，调用后 `address(EntityForging).balance == 2 ETH`。调用 `withdraw()` 会 revert（无此函数），2 ETH 仍在合约里。

**修复建议。**
退还差额，或要求精确付款：

```solidity
require(msg.value == forgingFee, 'Incorrect fee');
// 或者
uint256 refund = msg.value - forgingFee;
if (refund > 0) { (bool ok, ) = msg.sender.call{value: refund}(''); require(ok, 'Refund failed'); }
```

---

### F-06 —— 锻造者可被使用「上限 + 1」次

**严重度：** 中危
**位置：** `contracts/EntityForging/EntityForging.sol` —— 挂单检查 L87–90；执行时只自增 L133

**描述。**
挂单检查用的是对自增前值的非严格比较：

```solidity
// EntityForging.sol:87-90
require(forgingCounts[tokenId] <= forgePotential, ...);
```

执行路径只做自增：

```solidity
// EntityForging.sol:133
forgingCounts[forgerTokenId]++;
```

于是潜力为 `P` 的锻造者可以被使用 `P+1` 次：计数器等于 `P` 时挂单仍被接受，随后锻造把它推到 `P+1`，全程没有自增后的校验。合并方那一侧在 L140–144 是自增后校验的，正是这个不对称让问题显现。

**影响。**
每个锻造者多产出一枚子 token，供应量与对应空投额度随之膨胀。对一整代高潜力锻造者而言，超出量会逐代累积。

**复现。**
`test_PoC_P5_forgerUsedPotentialPlusOne`。构造一个熵值使 `forgePotential = 2` 的锻造者，挂单一次，用三个不同合并者锻造三次。

观测结果：三次全部成功，`forgingCounts(1) == 3`，即 `P+1`。

**修复建议。**
改用严格比较，或像合并方那样在自增后校验：

```solidity
require(forgingCounts[tokenId] < forgePotential, ...);
```

---

### F-07 —— 销毁 NFT 扣的是最初铸造者的空投额度，不是当前持有者的

**严重度：** 中危
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— 销毁路径 L146–149；`initialOwners` 写入 L294 与 L329，转账时不更新

**描述。**
销毁时扣减的是**第一个**所有者的空投额度：

```solidity
// TraitForgeNft.sol:146-149
if (!airdropStarted) {
  airdropContract.subUserAmount(initialOwners[tokenId], tokenEntropy[tokenId]);
}
```

`initialOwners[tokenId]` 只在铸造时写入，转账不会更新。真正销毁、也真正付过钱的当前持有者完全没被考虑。

**影响。**
买家可以买下 token 后销毁，从而削减**第三方**（最初铸造者）的额度，而自己的额度分文未动。这是一个只花 gas 的骚扰路径，且对买到的每一枚都可重复。同时，扣减被记在错误账户上，任何建立在 `subUserAmount` 之上的记账都会系统性出错。

**复现。**
`test_PoC_P7_burnDebitsOriginalMinter`。Mock 空投合约记录扣减调用：Alice 铸造、转给 Bob、Bob 销毁。

观测结果：被扣减的对象是 **Alice**（最初铸造者），不是 Bob（销毁者与当前持有者）。

**修复建议。**
扣当前持有者：

```solidity
airdropContract.subUserAmount(ownerOf(tokenId), tokenEntropy[tokenId]);
```

并在空投合约中明确额度是跟随 token 还是跟随账户。

---

### F-08 —— 所有合约的暂停机制都无法触达

**严重度：** 低危（安全机制失效，无直接资金损失）
**位置：** 六个合约均继承 OpenZeppelin `Pausable`，但没有任何一个暴露 `pause()` / `unpause()`

**描述。**
每个合约都在状态改变入口上挂了 `whenNotPaused`，也都继承了 `Pausable`，但没有一个定义或暴露 `pause()` 或 `unpause()`。在 OpenZeppelin 4.9.x 中 `_pause()` 与 `_unpause()` 都是 `internal`，除非合约自己开一个入口，否则无法调用。

**影响。**
紧急停止机制不存在。所有 `whenNotPaused` 都是死代码，`paused()` 永远返回 `false`。一旦出事，所有者没有办法在准备修复期间暂停铸造、锻造、交易或金库赔付。

**复现。**
`test_PoC_P8_pauseUnreachable`：对合约发起 `pause()` 选择子的低层调用会 revert（既没有该函数也没有 fallback），`paused()` 恒为 `false`，且没有任何入口能改变它。

**修复建议。**
把暂停权暴露给一个与金库操作不同的角色：

```solidity
function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
```

---

### F-09 —— 金库地址可被设为 `address(0)`，铸造款被静默销毁

**严重度：** 低危
**位置：** `contracts/TraitForgeNft/TraitForgeNft.sol` —— setter L66–71；付款 L361

**描述。**
`setNukeFundContract` 不做任何校验，而 `_distributeFunds` 通过低层 call 转账：

```solidity
// TraitForgeNft.sol:361
(bool success, ) = nukeFundAddress.call{value: mintPrice}('');
require(success, 'Transfer to NukeFund failed');
```

对 `address(0)` 的调用会返回 `true`，所以金库地址配错时，每一笔铸造款都会被销毁而不是回滚。`EntityForging.setNukeFundAddress`（L30–34）对锻造费分成存在同样的缺口。

**影响。**
铸造款与锻造费在交易层面静默消失，不报错，唯一的表现是金库余额对不上。

**复现。**
`test_PoC_P9_zeroTreasuryBurnsFunds`：把金库设为 `address(0)` 后铸造一笔，交易成功，NFT 合约余额为 0，付款的 ETH 没有到达任何合约。

**修复建议。**
两个 setter 都加上：

```solidity
require(newNukeFund != address(0), 'Zero address');
```

---

### F-10 —— 换代要求熵生成器的所有权，而转移所有权会让管理角色消失

**严重度：** 中危（不损失资金；停摆只持续到 owner 转移所有权，而转移本身是一次特权配置操作）
**位置：** `contracts/EntropyGenerator/EntropyGenerator.sol` —— `initializeAlphaIndices()` 位于 L206（`whenNotPaused onlyOwner`）；调用点在 `contracts/TraitForgeNft/TraitForgeNft.sol` 的 `_incrementGeneration()` L353

**描述。**
换代路径调用了一个「调用者没有权限调用」的函数：

```solidity
// TraitForgeNft.sol:353
entropyGenerator.initializeAlphaIndices();
```

```solidity
// EntropyGenerator.sol:206
function initializeAlphaIndices() public whenNotPaused onlyOwner {
```

生成器是独立部署的，构造函数只设了 `allowedCaller = _traitForgetNft`（L30–33），`Ownable.owner` 仍是部署者。也就是说 NFT 合约是**被允许的调用者**，从来不是**所有者**。于是每一笔把某一代铸满的 mint 都会在换代处 revert——直到 owner 把生成器的所有权转给 NFT。

文档给出的绕法就是这次转移。它确实能让换代跑通，但也让生成器的 owner 变成一个合约：`setAllowedCaller`（唯一的角色轮换入口）以及之后新增的任何 `onlyOwner` 函数——包括 F-08 提议的 `pause()`——都只有 `TraitForgeNft` 能调，而它没有任何转发路径。这次转移并没有给 NFT 任何它原本没有的东西（构造函数里它已经是 `allowedCaller`），它唯一的作用是删掉管理员。

**影响。** 部署只能在两个不理想的状态里二选一：

- **不转移**——铸造在第 10,000 枚（第 1 代末尾）停下，直到 owner 转移所有权。产品宣称的 10 万枚世代模型在这段时间里不可达，而且失败点正好落在换代边界，此时整代已经售出。不损失资金：每一笔失败的 mint 都会 revert。
- **转移**——铸造继续，但生成器此后没有可触达的管理员：NFT 换部署或新增第二个 minter 时无法轮换 allowed caller，也无法给这个喂给每一笔 mint 的合约安装紧急停止。

两者原则上都可恢复（转移所有权，或重新部署生成器），所以这是设计与部署层面的隐患，不是永久性损失。它之所以算 finding 而不是备注，是因为协议同时需要的两个性质——「NFT 能触发换代」和「人能管理生成器」——在现在的代码里互斥：这两份合约不存在同时满足两者的部署配置，要修就得改代码（即下面的补丁）。

**复现。**
`test_PoC_P10_rolloverRevertsWithoutOwnershipTransfer`：真实接线、不转移所有权。把 `generationMintCounts[1]` 设到上限后，下一笔 mint 以 `Ownable: caller is not the owner` revert，`currentGeneration` 仍是 1，没有铸出 token。

`test_PoC_P11_ownershipTransferStrandsEntropyAdmin`：同一套接线，然后由部署方（当前 owner）执行 `entropy.transferOwnership(nft)`。转移成功，`entropy.owner()` 变成 NFT 合约，随后部署者调用 `setAllowedCaller` 以 `Ownable: caller is not the owner` revert。

**修复建议。**
不要用所有权，给 NFT 一个调用者角色——`allowedCaller` 本来就存在且已指向 NFT：

```solidity
modifier onlyOwnerOrAllowedCaller() {
  require(msg.sender == owner() || msg.sender == allowedCaller, 'Caller is not allowed');
  _;
}

function initializeAlphaIndices() public whenNotPaused onlyOwnerOrAllowedCaller { ... }
```

并从部署流程里去掉所有权转移。`fixes/F-10/` 就是这版补丁；打了它，F-08 的 `pause()` 仍然可调。

---

### F-11 —— `taxCut` 被当作除数：只要不是 10，三处费率都会算错；设为 0 会让三个合约直接不可用

**严重度：** 低危（需要 owner 主动改参数；部署值 10 时费率正确）
**位置：** `contracts/EntityForging/EntityForging.sol` L146；`contracts/EntityTrading/EntityTrading.sol` L72；`contracts/NukeFund/NukeFund.sol` L41。setter：EF L36、ET L33、NF L63。

**描述。**
`taxCut` 的语义是百分比（默认 `10`，注释写着 "10%"），但三处用法都是**除以它**：

```solidity
// EntityForging.sol:146
uint256 devFee = forgingFee / taxCut;
// EntityTrading.sol:72
uint256 nukeFundContribution = msg.value / taxCut;
// NukeFund.sol:41
uint256 devShare = msg.value / taxCut;
```

`x / 10` 恰好等于 `x × 10%`，只因为 `10 == 100 / 10`。改这个值，分成会反向走：设成 5% 变成 20%，设成 20% 变成 5%。设成 0 则三处除法全部 revert，锻造、交易、金库分配三条路径一起停摆。三个 `setTaxCut`（`onlyOwner`）都没有做任何校验。

**影响。**
一次特权参数修改会静默改变三个合约的费率走向，设成 0 则直接不可用。没有外部攻击者能触发：部署值是 10，所以这个 bug 在 owner 改参数之前处于休眠状态——这也是本报告按 **低危** 记录的原因（公开结论里同一问题被定为 High，定级差异见 §5 的对照表）。

**复现。**
`test_PoC_P12_taxCutDivisorMisprices`（[`test/EntityForgingPoC.t.sol`](test/EntityForgingPoC.t.sol)）：把 `taxCut` 改成 5 后，一笔 1 ETH 的锻造给金库 **0.2 ETH**（20%）、给锻造者 **0.8 ETH**，而正确值是 0.05 / 0.95；再把 `taxCut` 设为 0，下一笔锻造在除法处 revert。

**修复建议。**
改成乘法，并给 setter 加上界：

```solidity
uint256 devFee = (forgingFee * taxCut) / 100;
// 三个 setter 都加
require(_taxCut > 0 && _taxCut <= 100, 'Invalid tax cut');
```

补丁在 `fixes/F-11/`（三处公式 + 三个 setter）。

---

## 五、范围外与限制

- **空投合约。** 只拿到 `IAirdrop` 接口，实现不在本次审查内。F-07 的最终影响取决于 `subUserAmount` 如何处理下溢，这一点无法验证。
- **熵生成器的所有权（F-10）。** 生成器必须同时「可被 NFT 调用」和「可被人管理」，而现行权限模型让这两件事互斥。P10 量化第一种失效（不转移所有权时换代被卡死），P11 量化第二种（转移后不再有外部 owner）。两者都跑在真实接线上。
- **接线方式。** P3、P4、P6、P10、P11 跑的是**真实** `EntropyGenerator`（先在部署者仍是 owner 时写完 entropy batch、初始化 alpha indices，**最后**才转移所有权；P10/P11 故意不转移或转移后再验证）与真实 `EntityForging`，只有 Airdrop 是 mock（实现不在范围内）。P7 保留 `MockEntropyGenerator`，因为它需要指定熵值；P2、P8、P9 用轻量接线（`MockForgingRegistry` + mock 熵），因为它们只考察 NFT 合约本身；P5 的锻造者属性直接读熵流，所以它并不是「与熵无关」。
- **注入的状态，逐条。** P3 的第 2 代计数（8）来自**八次真实 `forgeWithListed`**（等于该锻造者的 potential）；之后只把第 1 代标成满额（公开路径要 1 万次 mint 才能到，测试里做不到），`_tokenIds` 保持与真实 token 数一致。P4 把第 10 代标满（≈10 万次 mint、测试规模下约 1,275 ETH 手续费）。P6 只把第 1 代标满。P2 把 `_tokenIds` 设成 10,000。早先那版 P3 直接把预填写进存储、没有证明可达性，这一点已经改掉；P4 仍是最弱的一条，只有 `currentGeneration` 与 `generationMintCounts[10]` 被快进，其余不变式与该状态并不自洽，应读作「这条代码路径没有上界」，而不是可达的端到端场景。
- **来源说明。** 结论来自两次在不看公开结论的情况下过冻结源码，PoC 是之后补写的。但代码和答案都是公开的（Code4rena 2024-07），隔离只是流程上的，无法强制执行：不能排除模型记得这道公开赛题，所以不能把这份报告读成"在没有答案的情况下也会得出同样结果"。冻结时存在的九条结论里 8 条与公开结论重合；**F-10 与 F-11 是定稿交叉核对时补入的**，已如实标注。
- **与公开结论的定级差异。** 有五条定级不同，理由逐条列出：

| 公开编号 | 本报告 | 公开定级 | 本报告定级 | 理由 |
|---|---|---|---|---|
| H-01 批量铸造在 1 万枚后失效 | F-02 | High | 中危 | 调用会全额退款、单枚铸造照常；只有批量入口失效，不涉及资金风险。 |
| H-02 卖出后的空投额度被恶意扣减 | F-07 | High | 中危 | 扣的是第三方空投额度而非本金，攻击者没有收益；空投实现不在范围内，最坏情况（下溢导致 burn revert）无法实测。 |
| H-03 `taxCut` 当除数 | F-11 | High | 低危 | 只有 owner 改参数后才触发，部署值 10 时分成正确。收录是因为改错会静默错分费率、设 0 会让三个合约不可用——但它属于配置错误，不是攻击者路径。 |
| H-06 换代 DoS | F-10 | High | 中危 | 停摆可由 owner 转移所有权恢复，且不损失资金。 |
| M-13 pause 不可用 | F-08 | Medium | 低危 | 失效的安全机制，没有直接资金损失。 |

  规则写在 §3，三份报告用同一套：需要特权角色先设非法值的，记 Low；自身造成或有界的损失，记 Medium——不管公开结论怎么定。

- **未做模糊测试或不变式测试。** 结论来自人工阅读加定向执行。
- **严重度是判断**，不是链上事实。

---

## 六、附录 —— PoC 套件

```bash
# 在仓库根目录执行
forge test -vv
```

环境：Foundry 1.8.5、solc 0.8.25、`via_ir = false`、OpenZeppelin 4.9.3。

| 测试 | 对应问题 | 断言内容 |
|---|---|---|
| `test_PoC_P1_excessPaymentLocked` | F-05 | 3 ETH 付款中有 2 ETH 留在合约 |
| `test_PoC_P2_mintWithBudgetDeadAfterMaxSupply` | F-02 | `_tokenIds = 10_000` 后铸出 0 枚并全额退款 |
| `test_PoC_P3_generationCountWipedOnRollover` | F-03 | 8 次真实 `forgeWithListed` 产生的第 2 代计数被重置（断言期望 1，正确值 N+1 = 9） |
| `test_PoC_P4_generationExceedsMaxGeneration` | F-01 | `maxGeneration = 10` 时 `currentGeneration` 达到 11 |
| `test_PoC_P5_forgerUsedPotentialPlusOne` | F-06 | `forgingCounts == P + 1` |
| `test_PoC_P6_priceOverchargeAtGenerationRollover` | F-04 | 售价 0.005 ETH 的 token 被收了 0.25 ETH |
| `test_PoC_P7_burnDebitsOriginalMinter` | F-07 | 扣减被记到前任持有者名下 |
| `test_PoC_P8_pauseUnreachable` | F-08 | 合约无法调用 `pause()`，`paused()` 恒为 false |
| `test_PoC_P9_zeroTreasuryBurnsFunds` | F-09 | 金库为零地址时铸造款被销毁 |
| `test_PoC_P10_rolloverRevertsWithoutOwnershipTransfer` | F-10 | NFT 不持有生成器时，换代 mint 直接 revert |
| `test_PoC_P11_ownershipTransferStrandsEntropyAdmin` | F-10 | 转移所有权后，没有任何外部账户还能调用 `setAllowedCaller` |
| `test_PoC_P12_taxCutDivisorMisprices` | F-11 | 5% 的税率应该收 5%，实际收了 20% |

全部测试在受审 commit 上通过。**11 条 finding / 12 个测试的 fix-fail 全部实测**：每条都有 `fixes/F-0x/` 补丁树，对应测试均失败。失败方式分三类：**4 条 revert**（P1/P4/P5/P9，在新加的防护处）；**6 条状态断言**（P2/P3/P6/P7/P8/P12）；**2 条 `expectRevert` 没有等到 revert**（P10/P11，只能说明漏洞行为消失了，不能说明某个状态断言抓到了它）。每条的失败文本逐字见英文版附录（同一命令可复现）。F-03 用的是"不清零"方案；"禁止锻造进未来世代"会让 setup 阶段直接 revert。

fix-fail 只证明 PoC 对**某个**补丁敏感，不证明补丁本身正确。合并后的补丁另外测过：`fixes/ALL/` 是十一条修复合并后的源码，12 个测试在那里全部失败；[`test/Regression.t.sol`](test/Regression.t.sol) 则验证正常流程在补丁版上仍然正确。

合并本身也抓到了真问题：第一版合并树里，`mintWithBudget` 每 mint 一枚就 settle 一次；批量买到最后一代第 10000 枚时，这次 settle 撞上 F-01 新加的世代上界，**整笔调用连同已经 mint 的部分一起回滚**，导致最后一枚永远无法通过批量购买获得。回归测试先红（`[FAIL: Exceeds max generations]`），修在 F-04（最后一代满额时先 `break` 再 settle，余额退回），然后重新合并。

| 回归测试 | 固定住的语义 |
|---|---|
| `test_regression_singleMint` | 公开铸造仍可用，仍按开盘价收费 |
| `test_regression_forgeAtExactFee` | 按准确费用锻造仍可用，仍按 90/10 分账 |
| `test_regression_realForge` | 同上，但跑在真实 `TraitForgeNft` + 真实 `EntityForging` 上（熵值可控） |
| `test_regression_patch_rolloverKeepsPrefillAndPrice` | 换代既保留预填计数，又让新价格曲线**从预填处**继续（第 6 枚为 0.0051475 ETH） |
| `test_regression_patch_budgetMintAcrossBoundary` | 批量跨 1→2 代能正确 mint 与退款；批量买到最后一代上限时停下而不是回滚 |
| `test_regression_patch_burnDebitsCurrentOwner` | 转手后销毁，扣的是当前持有者的空投额度（F-07） |
| `test_regression_patch_pauseStopsMinting` | F-08 的 pause 能停铸，unpause 能恢复 |
| `test_regression_patch_guards` | F-05/F-09 的拒绝路径生效，而不是吞钱/锁钱 |
| `test_regression_patch_entropyCallerRole` | F-10 让部署者保留所有权时换代也能跑通 |

```bash
forge test --remappings 'traitforge/=fixes/ALL/src/' --match-path test/Regression.t.sol
# 期望：9 passed
```

在未修复的源码上，六个 `test_regression_patch_*` 会被标为 skipped（此时还没有可回归的修复行为），所以 `forge test` 在受审 commit 上仍然是绿的：16 passed、6 skipped。
