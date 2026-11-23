# 智能合约安全审计报告 —— StakingRewards

**审查对象：** `src/StakingRewards.sol`（159 行）
**来源：** `https://github.com/JohnDonuttt/staking-rewards`，commit `b7979864b1f6cc0091838199a0befaab9207a1f4`（`src/StakingRewards.sol` blob `ecccfbbe1f84f6d54d118c77094ec1c6692b429e`；本目录文件逐字节一致，sha256 `b29bf4b3…`）
**编译器：** solc 0.8.25，OpenZeppelin Contracts 5.2.0
**日期：** 2026 年 11 月

---

## 一、摘要

单合约质押池：用户质押一种代币，按固定速率在奖励周期内获得另一种代币，采用 Synthetix 的 `rewardPerToken` 累加器模型。

共报告 3 个问题：**1 高危、1 中危、1 低危**。高危是记账问题——同一笔奖励余额可以被承诺给两个周期，第二个周期的用户最后发现无钱可领。三条都有测试复现，见 [`test/`](test/)。

| 编号 | 严重度 | 标题 |
|---|---|---|
| F-01 | 高危 | 余额校验不含已累计未领取的负债，同一笔代币可被承诺两次 |
| F-02 | 中危 | 无人质押期间的奖励预算永久滞留 |
| F-03 | 低危 | 无质押余额时 `exit()` 直接 revert，而不是空操作 |

## 二、范围

| 文件 | 行数 | SHA-256 |
|---|---|---|
| `src/StakingRewards.sol` | 159 | `b29bf4b37fbe0fe0bbd849d50b7f9616a1bfd2c87731fafcad866fe6096aadd4` |
| `lib/openzeppelin-contracts` | — | OpenZeppelin 5.2.0 |
| `lib/forge-std` | — | 仅测试用 |

合约除 ERC-20 依赖外自包含，无代理、无升级、无预言机。

## 三、严重度定义

三份报告使用同一套定义：

| 级别 | 判定标准 |
|---|---|
| **高危** | 用户资金损失或核心不变式被破坏，且可通过文档化的流程、以合法输入触发；既不需要受害者自己填错金额，也不需要特权角色先设一个非法值。 |
| **中危** | 有界或自身造成的价值损失（多付、滞留、换代边界多收费）、经济扭曲，或正常使用下的拒绝服务。 |
| **低危** | 需要特权角色先设一个非法值（配置错误）、失效的安全机制，或没有直接资金损失。 |

F-01 按这条规则是高危：`notifyRewardAmount` 就是开周期的文档化入口，调用本身合法，也不需要特权**值**——本该拦下"无资金承诺"的检查存在且写错了，所以第二个周期的用户没有任何过错却拿不到钱。

特权调用如果本身经过合约自己的校验，仍算「文档化流程」；只有当代码对该输入完全没有校验时，错误值才被排除在 High 之外。这就是本条与「设了一个没人校验的地址或百分比」（TraitForge 报告里的低危条目）的区别。

## 四、问题详情

### F-01 —— 余额校验忽略已累计负债，同一笔代币被承诺两次

**严重度：** 高危
**位置：** `src/StakingRewards.sol` L145–151（`notifyRewardAmount` 的余额检查），对照 L74–77（`earned`）

**描述。**
开启新奖励周期时，合约检查自己持有的代币是否够发新速率：

```solidity
// L145-151
uint256 balance = rewardToken.balanceOf(address(this));
if (address(rewardToken) == address(stakingToken)) {
    balance -= totalStaked;
}
if (rewardRate * duration > balance) revert RewardTooHigh();
```

`balance` 是原始余额，**没有扣除已经累计给用户、但尚未领取的奖励**。这部分记在 `rewards[]` 里，只有调用 `getReward()` 才会变成转账。于是一笔已经被第一周期赚走的余额，看起来像没动过，可以再次被承诺给第二周期。

**影响。**
两个周期由同一笔余额支撑。第一周期用户领走后，第二周期用户照常累计奖励，但 `getReward()` 在 ERC-20 转账处 revert。配置时发现不了——`notifyRewardAmount` 会毫无怨言地接受第二个周期。

**复现。**
`test_PoC_budgetDoubleSpent_secondStakerUnpaid`（[`test/StakingRewardsPoC.t.sol`](test/StakingRewardsPoC.t.sol)）。

过程：Alice 质押满一个周期，累计到全部 100 枚预算但未领取；owner 不追加任何资金，再次用同样的 100 枚预算调用 `notifyRewardAmount`，调用成功；Alice 领走全部 100 枚；Bob 在第二周期质押并正常累计。

观测：Alice 领到 100，Bob 累计大于 0，合约余额 0，Bob 的 `getReward()` 因 `ERC20InsufficientBalance` revert。

**修复建议。**
承诺新周期前先扣掉**全局**负债，而不是每个用户各自的未领取数。

这里有个容易踩的坑：`notifyRewardAmount` 走的是 `updateReward(address(0))`，它不结算任何人，所以此刻 Alice 的 `rewards[alice]` 仍然是 0。**用"每个用户的未领取奖励"做扣减，检查照样通过，PoC 根本修不掉。** 必须是全局累加器。

```solidity
uint256 public outstanding; // 已累计但尚未支付的奖励

modifier updateReward(address account) {
    uint256 applicable = lastTimeRewardApplicable();
    if (totalStaked > 0 && applicable > lastUpdateTime) {
        outstanding += (applicable - lastUpdateTime) * rewardRate;
    }
    rewardPerTokenStored = rewardPerToken();
    lastUpdateTime = applicable;
    ...
}

function getReward() public nonReentrant updateReward(msg.sender) {
    uint256 reward = rewards[msg.sender];
    if (reward > 0) {
        rewards[msg.sender] = 0;
        outstanding -= reward;          // 负债结清
        rewardToken.safeTransfer(msg.sender, reward);
    }
}

// notifyRewardAmount 里
uint256 balance = rewardToken.balanceOf(address(this));
if (address(rewardToken) == address(stakingToken)) balance -= totalStaked;
if (rewardRate * duration > balance - outstanding) revert RewardTooHigh();
```

顺序很重要：`outstanding` 必须先更新到当前时刻再检查新速率。`updateReward(address(0))` 已经在做这件事，前提是累加器是全局的。

**修复验证。** `fixes/F-01/` 里有打上该补丁的合约副本，跑：

```bash
forge test --remappings 'pool/=fixes/F-01/src/' --match-test test_PoC_budgetDoubleSpent
# 期望：[FAIL: RewardTooHigh()]
```

---

### F-02 —— 无人质押期间的奖励预算永久滞留

**严重度：** 中危
**位置：** `src/StakingRewards.sol` L66–72（`rewardPerToken`）、L48–56（`updateReward`）、L137–143（滚动逻辑）

**描述。**
当 `totalStaked == 0` 时，`rewardPerToken()` 直接返回存储值，时间流逝但没有人累计：

```solidity
// L66-72
if (totalStaked == 0) return rewardPerTokenStored;
uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
```

下一次带 `updateReward` 修饰符的调用会把 `lastUpdateTime` 设为当前时间，这段间隔被静默丢弃。覆盖这段间隔的代币留在合约里，但滚动逻辑只在新周期于 `periodFinish` 之前开始时才把它计入：

```solidity
// L137-143
if (block.timestamp >= periodFinish) {
    rewardRate = reward / duration;
} else {
    uint256 leftover = remaining * rewardRate;
    rewardRate = (reward + leftover) / duration;
}
```

周期已经结束时，滞留代币永远不会被折回后续周期，也没有任何函数可以取走。

**影响。**
宣称的奖励没有完全发放。PoC 里一半预算永久不可达，这是"对外宣称"与"质押者实际能拿到"之间的直接差额。

**复现。**
`test_PoC_rewardsDroppedWhileNoStakers`。100 枚分 100 秒发放；前 50 秒无人质押；Alice 在后 50 秒质押。

观测：Alice 领到 50，50 滞留合约；不变式"已发放 + 滞留 == 预算"成立，即预算守恒但一半不可达。

**修复建议。**
把策略写进代码，三选一：

- 无人质押时暂停计时（不消耗周期）；
- 滞留部分可由 owner 取回（`recoverUnclaimed`）；
- 无条件并入下一周期。

静默留在合约里是唯一让用户吃亏的选项。

**冻结方案的代价。** `fixes/F-02/` 取的是第一种：`totalStaked == 0` 时同时前移 `lastUpdateTime` 与 `periodFinish`。预算保住了，但「宣布的结束时间」不再是真实结束时间——每一秒空转都会把它往后推。晚加入的质押者实际经历的周期比宣传的更长。这是行为变化，不是实现细节；如果不能接受，就选「owner 取回滞留部分」那一条，它保住时间线、代价是 owner 对用户奖励有索取权。两者都可辩护，静默吞掉不可辩护。

还有一层：链上存的 `periodFinish` **只在有交易时才会往后推**，所以空转期间它是过期的——前端（以及 `notifyRewardAmount` 里的 `PeriodNotFinished` 判断）读到的是旧结束时间，会把还在冻结的池子显示成「已结束」。因此补丁额外加了 `effectivePeriodFinish()`（`periodFinish` 加上待计入的空转时长），并在每次冻结时发 `PeriodExtended(newPeriodFinish)`。消费方应当读这个 view，而不是直接读存储变量——报告写明了这一点，免得修复在合约里是对的、在所有客户端里是错的。

---

### F-03 —— 无质押余额时 `exit()` 直接 revert

**严重度：** 低危
**位置：** `src/StakingRewards.sol` L114–117（`exit`）、L93–95（`withdraw`）

**描述。**
`exit()` 调用 `withdraw(balanceOf[msg.sender])`，而 `withdraw` 拒绝零金额：

```solidity
// L93-95
if (amount == 0) revert ZeroAmount();
```

已经赎回、但仍有未领奖励的用户无法使用 `exit()`：它在到达 `getReward()` 之前就 revert。

**影响。**
便利函数不可用，且报错误导——用户被告知调用非法，实际上他有奖励没领。

**复现。**
`test_PoC_exitRevertsWithoutStake`：零余额用户调用 `exit()`，收到 `ZeroAmount`。

**修复建议。**
在 `exit()` 内部做条件判断：

```solidity
function exit() external {
    uint256 balance = balanceOf[msg.sender];
    if (balance > 0) withdraw(balance);
    getReward();
}
```

## 五、范围外与限制

- 测试使用 mock ERC-20；不覆盖转账收费与 rebasing 代币，`safeTransfer` 的用法也说明并未打算支持。
- owner **不**被假定为恶意。F-01 走的是文档写明的注资流程（`notifyRewardAmount` 就是开周期的入口），因此不需要任何特权作恶——只需要 owner 把已经被赚走的预算再承诺一次。
- **来源。** 这是三个样本里唯一没有公开答案的一个：小型开源仓库，审查时没有找到覆盖这些函数的审计、竞赛报告或 issue 列表。源码经 `raw.githubusercontent.com` 取得并用 blob 哈希固定（见报告头），结论只从合约本身得出。这既是优点也是缺点：没有被公开答案影响，也没有外部评审确认过——严重度只是一位评审者的判断。
- 未做模糊测试与不变式测试；结论来自人工阅读加定向执行。
- 严重度是判断，不是部署代码的事实。

## 六、附录

```bash
forge test -vv
```

| 测试 | 对应问题 | 修复后是否失败 |
|---|---|---|
| `test_PoC_budgetDoubleSpent_secondStakerUnpaid` | F-01 | **是**（`fixes/F-01/` 全局负债补丁，报 `RewardTooHigh()`） |
| `test_PoC_rewardsDroppedWhileNoStakers` | F-02 | **是**（`fixes/F-02/`：`totalStaked == 0` 时暂停计时；断言变成 `100000000000000000000 != 50000000000000000000`） |
| `test_PoC_exitRevertsWithoutStake` | F-03 | **是**（独立的 `fixes/F-03/` 补丁树，不再借用 F-02 那棵；`expectRevert` 不再 revert） |

复现已验证的那条：

```bash
forge test --remappings 'pool/=fixes/F-01/src/' --match-test test_PoC_budgetDoubleSpent
# 期望：[FAIL: RewardTooHigh()]
```

### 合并补丁

`fixes/ALL/src/` 是三处修复合并后的源码。F-01 和 F-02 改的是**同一个 `updateReward` 修饰符**，所以逐个补丁测从来没有测过它们能否共存——合并这两棵树时真的冲突了（F-01 在这里累加全局负债，F-02 在这里冻结空闲周期），冲突在 `fixes/ALL/` 里手工解决：冻结分支只在 `totalStaked == 0` 时走，负债累加只在 `totalStaked > 0` 时走，两边互不污染。

3 个 PoC 在合并树上仍然全部失败（`logs/all-poc-fail.txt`），[`test/Regression.t.sol`](test/Regression.t.sol) 则验证修复不能破坏的流程：整周期质押仍拿满预算、两个质押者仍按比例分、**1 wei 质押后立刻领取仍约等于 0**、无资金的第二个周期会被拒绝、空闲窗口不再滞留预算（且 `periodFinish` 正好后移空闲时长）、**空闲之后再次注入预算仍会被拒**（已累计的负债被计入）、全部赎回后 `exit()` 仍能领到奖励。

```bash
forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# 期望：6 passed
```

在未修复的源码上，同一文件里只在修复后成立的三条会显示为 `[SKIP]`，所以 `forge test` 在受审 commit 上仍然全绿（7 passed / 3 skipped）。
