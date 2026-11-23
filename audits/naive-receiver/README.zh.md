# 智能合约安全审计报告 —— NaiveReceiver

**审查对象：** `src/NaiveReceiverPool.sol`、`src/BasicForwarder.sol`、`src/FlashLoanReceiver.sol`、`src/Multicall.sol`
**编译器：** solc 0.8.25，OpenZeppelin 5.2.0，Solmate，Solady
**日期：** 2026 年 11 月

---

## 一、摘要

一个提供 ERC-3156 闪电贷的 WETH 池，配了一个元交易转发器，让用户可以经由中继者操作。报告两个问题，**都是高危**，且都是"什么都不用做就被拿走钱"。

| 编号 | 严重度 | 标题 |
|---|---|---|
| F-01 | 高危 | 任何人可以以任意 receiver 的名义发起闪电贷，手续费由 receiver 承担 |
| F-02 | 高危 | 发送者身份取自 calldata 尾部字节，转发器用户可冒充任意存款人 |

两条都有复现测试（见 [`test/`](test/)），第二条在一笔交易里把 1,000 WETH 转出池子。

## 二、范围

| 文件 | 行数 | SHA-256 |
|---|---|---|
| `src/NaiveReceiverPool.sol` | 93 | `4321f8d50fe23c0eed9b018eb053bce923d845a5a93afed004478f6c50969e28` |
| `src/BasicForwarder.sol` | 104 | `1a851a894c8bf3b1608bab7c42b69418a9111e0b7349c148989ea0e233fca13f` |
| `src/FlashLoanReceiver.sol` | 41 | `752287c8908ba00f49679aed8e9d826122813b42f874f5bc10f8c2a1bfac069c` |
| `src/Multicall.sol` | 14 | `6d7bf6e03ba4f1f3cc9f29b5dd17bfaf9ff1700209a5a09910ebd18b83864d5f` |

这些是 Damn Vulnerable DeFi v4 随挑战分发的合约，此处复制过来，使复现不必依赖整个仓库。

## 三、严重度定义

三份报告使用同一套定义：

| 级别 | 判定标准 |
|---|---|
| **高危** | 用户资金损失或核心不变式被破坏，且可通过文档化的流程、以合法输入触发；既不需要受害者自己填错金额，也不需要特权角色先设一个非法值。 |
| **中危** | 有界或自身造成的价值损失（多付、滞留、换代边界多收费）、经济扭曲，或正常使用下的拒绝服务。 |
| **低危** | 需要特权角色先设一个非法值（配置错误）、失效的安全机制，或没有直接资金损失。 |

本目录的两条都属高危：任何账户都能触发，调用都是常规调用，损失的是他人的资金。

特权调用如果本身经过合约自己的校验，仍算「文档化流程」；只有当代码对该输入完全没有校验时，错误值才被排除在 High 之外。本目录的两条完全不依赖特权角色，因此不涉及这个区分。

## 四、问题详情

### F-01 —— 任何人可以以任意 receiver 的名义发起闪电贷

**严重度：** 高危
**位置：** `src/NaiveReceiverPool.sol` L43–64

**描述。**
`flashLoan` 把 receiver 作为参数接收，却从不校验调用者与 receiver 的关系：

```solidity
// L43-58
function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
    external
    returns (bool)
{
    if (token != address(weth)) revert UnsupportedCurrency();
    weth.transfer(address(receiver), amount);
    totalDeposits -= amount;
    if (receiver.onFlashLoan(msg.sender, address(weth), amount, FIXED_FEE, data) != CALLBACK_SUCCESS) {
        revert CallbackFailed();
    }
    uint256 amountWithFee = amount + FIXED_FEE;
    weth.transferFrom(address(receiver), address(this), amountWithFee);
```

手续费固定 1 WETH，与借款金额无关，且由 receiver 支付而非调用者。ERC-3156 的回调签名本来就不认证发起方，因此 receiver 无法区分正常请求与恶意请求。

**影响。**
任何持有 WETH 且实现 `onFlashLoan` 的合约，都可以被反复以零额度借款耗尽。每次调用攻击者只花 gas，受害者损失 1 WETH。受害者甚至不需要与池子有过任何交互，只要账上有余额。

**复现。**
`test_PoC_N01_unprotectedFlashLoanDrainsReceiver`。receiver 持有 10 WETH，攻击者没有任何资产，连续调用 `flashLoan(receiver, weth, 0, "")` 十次。

观测：receiver 余额 10 → 0，手续费收款人记账增加 10 WETH，攻击者余额仍是 0。这是循环，不是一次性事件。

**修复建议。**
要求发起方获得 receiver 的同意。最直接的写法是把调用者与 receiver 绑定：

```solidity
if (msg.sender != address(receiver)) revert Unauthorized();
```

如果产品上确实需要第三方代为发起，就必须让 receiver 预先授权发起方，池子在转账前查这张白名单。

**这个修复的代价必须写明。** 把调用者绑到 `msg.sender` 之后，**receiver 自己经转发器发起**的闪电贷也会被拒：那时 `msg.sender` 是转发器，不是 receiver；任何替 receiver 代发的路由/批处理合约同理。直接调用池子的 receiver 不受影响；需要元交易的 receiver 必须用白名单那种写法（或基于 `_msgSender()` 的校验），不能用这一行判断。`fixes/F-01/` 里就是这一行判断，回归测试覆盖的是直接调用那一种（`test_regression_selfInitiatedFlashLoan`）。

---

### F-02 —— 发送者身份取自 calldata 尾部字节，可被冒充

**严重度：** 高危
**位置：** `src/NaiveReceiverPool.sol` L86–92（`_msgSender`），与 `src/BasicForwarder.sol` L63、`src/Multicall.sol` L11–19 联动

**描述。**
池子通过读取 calldata 最后 20 字节来还原元交易里的"真实发送者"：

```solidity
// NaiveReceiverPool.sol L86-92
function _msgSender() internal view override returns (address) {
    if (msg.sender == trustedForwarder && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    } else {
        return super._msgSender();
    }
}
```

转发器会在转发的负载末尾拼上 `request.from`（`BasicForwarder.sol` L63），所以尾部被信任。但 `Multicall` 用 `Address.functionDelegateCall(address(this), data[i])` 执行每个子调用——delegatecall 会保留 `msg.sender` 为转发器，而 `msg.data` 是调用者自己提供的。于是在这样的子调用里，数据的作者控制了最后 20 字节，池子把它当成了发送者。

**影响。**
任何能让一条已签名请求经由转发器执行的用户——也就是这个池子的正常用法——都可以在 `withdraw` 调用尾部拼上任意地址，取走该地址的存款。转发器的签名校验只认证攻击者自己的地址，与被打冒充的账户无关。

**复现。**
`test_PoC_N02_forwarderSpoofStealsVictimDeposit`。

过程：受害者（部署者）在池中存入 1,000 WETH；攻击者生成一对密钥，构造 `withdraw(1000e18, attacker)` 的 calldata，尾部拼上受害者地址，包成单个 `multicall` 子调用，并以自己的身份签名请求；转发器按 `request.from = attacker` 校验签名并执行。

观测：`deposits[victim]` 1,000 → 0，攻击者 WETH 余额 0 → 1,000，池子余额 0。

**修复建议。**
绝不要从调用者能影响的数据后缀推导身份。按优先级：

1. 去掉 `_msgSender()`，让转发器调用一个把 sender 作为**命名参数**并纳入签名的函数（例如 `executeFor(address from, ...)` 配 nonce 校验）——地址由签名认证，而不是由字节位置决定。
2. 如果必须保留 ERC-2771 风格，让 `Multicall` 拒绝对以 20 字节后缀结尾的数据做 delegatecall，或让 `_msgSender()` 在 delegatecall 上下文（`address(this) == msg.sender` 不成立）时不读尾部。
3. 至少把 `msg.data.length >= 20` 改成每个函数精确的 `selector 长度 + 20`。

## 五、范围外与限制

- `FlashLoanReceiver` 是受害者夹具而非生产合约；它的 `onFlashLoan` 正确校验了调用者是池子，所以只能被抽走手续费。
- 转发器的签名方案（EIP-712、nonce、deadline）本身没有被打穿。
- 未做模糊测试与不变式测试；结论来自人工阅读加定向执行。
- 这些合约是刻意留有漏洞的教学靶场，此处按审计报告的口径呈现。
- **来源。** 两个问题都属于 Damn Vulnerable DeFi 的公开题目，题目和答案都是公开的，本目录是**复现**：PoC 是在已知答案的背景下写的，没有任何"独立发现"的声明。这两个问题本身广为人知，所以这份材料的价值在验证链（状态断言、逐补丁失败、合并树回归），不在发现。
- **未覆盖。** 只审了上面两个问题，挑战合约的其余行为没有深入审查。

## 六、附录

```bash
forge test -vv
```

| 测试 | 对应问题 | 修复后是否失败 |
|---|---|---|
| `test_PoC_N01_unprotectedFlashLoanDrainsReceiver` | F-01 | **是**（`fixes/F-01/` 加 `msg.sender == receiver`，PoC 以 `Unauthorized()` revert） |
| `test_PoC_N02_forwarderSpoofStealsVictimDeposit` | F-02 | **是**（`fixes/F-02/` 拒绝转发器发起的 `multicall`，受害者存款保持 1,000 WETH） |

F-02 修复的代价必须写明：拒绝转发器发起的 `multicall` 也一并去掉了批量元交易。这是固有的——delegatecall 的数据尾部无法在 `_msgSender()` 内部被认证——所以这是在"批量"与"可伪造的发送者"之间二选一，不是免费修复。

### 合并补丁

`fixes/ALL/src/` 是两处修复合并后的源码（两者分别改 `NaiveReceiverPool.flashLoan` 和 `multicall` 覆写，不同文件，合并无冲突）。两个 PoC 在合并树上仍然失败（`logs/all-poc-fail.txt`），[`test/Regression.t.sol`](test/Regression.t.sol) 则验证不能被破坏的流程：receiver 自己发起的闪电贷仍然可用、存取往返正常、**单笔**转发调用仍能通过 `request.from` 认证、伪造的 multicall 被拒绝且受害者存款完好。

```bash
forge test --remappings 'pool/=fixes/ALL/src/' --match-path test/Regression.t.sol
# 期望：4 passed
```
