# 本地内核架构 — 设计决策与桌面端复用清单

> 读者：要改内核、要接 Android 宿主、或要新增引擎适配器的人。
> 协议面（对外契约）在 `kernel-api.md`；本文讲**为什么**。

---

## 1. 问题与目标形态

桌面端 DSH-Mizar 的能力来自「桌面 DSH 引擎 + 宿主插件 + 中继」三件套；手机
永远只是监视器。本地内核要回答的问题是：**没有桌面电脑时，手机自己当
宿主**。约束：

- iOS 与 Android 必须跑**同一个内核**（一份逻辑，两端行为一致）。
- GUI 与内核**解耦**——GUI 通过协议通信，内核可以独立测试、独立演进。
- **复用桌面端已验证的协议面**：客户端连接层（iOS `MizarConnection`、
  Android `mizarkit`）不做任何修改就能切换宿主类型。

## 2. 四个关键决策

### 决策 1：内核说 Mizar 协议 v1，而不是发明新协议

`dsh-mizar` 的 `src/protocol/frames.ts` 是纯 TypeScript、零 Node 依赖——
直接改编（GPL 同源，见文件头）作为内核的协议层。收益：

- iOS `MizarConnection` 是纯协议客户端，`WebSocketTransport` 注入点
  （`MizarConnection.init(makeTransport:)`）换上 `LocalKernelTransport`
  即可，**连接层、重连计划、关联 id、事件流全部复用**；
- Android `mizarkit` 同理（第二实现互为校验）；
- 桌面端的黄金帧契约测试（`protocol/fixtures/`）直接变成内核的测试资产。

### 决策 2：内核自带会话存储，而不是实现 DSH 网关接口

桌面插件的会话事实来自 DSH 上游的投影服务（140 endpoint 的 Typert 面）。
内核没有宿主，两条路：(a) 实现 Typert 网关接口再跑桌面插件；(b) 内核自带
存储、把桌面**方法表语义**逐字实现一遍。选 (b)：

- Typert 面 140 个 endpoint、40+ 事件变体，内核只需要其中 5 种记录类型；
- 桌面插件对客户端的承诺都在**方法表语义**里（summary 白名单、256 KiB
  预算、activity 行规则、stats 缺失≠零），这些是可移植的纯逻辑；
- 引擎无关性由此天然成立：内核之上不再有「DSH 特有」的概念。

### 决策 3：回调式 PlatformHost，而不是 Promise 式

JS 引擎（JSC/QuickJS/Hermes）对原生 Promise 的桥接各不相同，是嵌入层的
经典碎点。内核的 `PlatformHost` 全部回调风格；内核内部用 20 行
`fromCallback` 包装成 Promise。宿主只需「后台线程跑慢活、回 JS 线程调
回调」。

**iOS 嵌入的已知怪癖**（Android 宿主注意）：对「闭包捕获类私有状态的
函数」从原生直接 `JSValue.call` 会静默停摆；宿主一律通过**对象上的
`invokeMethod`** 投递回调（HTTP 桥因此把 handlers 对象整体持有并以
`handlers.invokeMethod("onDone", …)` 投递——与 fs/kv 回调的投递路径完全
一致）。这是实测发现的平台怪癖，不是理论风险。

### 决策 4：引擎适配器收敛在「一步一调用」

三家桌面宿主（dsh / CC-Mizar / codex）的共同经验：引擎特有面收敛于
「驱动引擎 + 把引擎事实投影成 5 种标准记录 + 保证 seq 契约」。内核的
`EngineAdapter` 只有一个方法：**一步 = 一次引擎调用**，流式 delta 回调、
取消信号、工具调用列表、usage。回合运行器拥有其余一切（历史组装、记录、
门控、审批、取消、崩溃闭合）。

未来接入 Claude Code / Codex 的路径：实现 `EngineAdapter`（驱动各自进程/
app-server、投影 delta 与 tool calls），内核其余部分零改动。

## 3. 桌面端代码复用清单

| 内核文件 | 来源 | 复用方式 |
|---|---|---|
| `src/protocol/frames.ts` | `dsh/src/protocol/frames.ts` | 改编（去配对 HTTP 面，注释注明来源与差异） |
| `src/protocol/method-error.ts` | `dsh/src/bridge/method-error.ts` | 改编 |
| `src/core/delivery.ts` | `dsh/src/bridge/delivery.ts` | 逐语义移植（记账只在送达后前移） |
| `src/core/interactions.ts` | `dsh/src/bridge/interactions.ts` | 逐语义移植（fail-closed、先删后答、计数通知） |
| `src/core/records.ts` | `dsh/src/bridge/sessions.ts` | summary/activity 投影逐条移植（白名单、预算、240 字符、running-turn 规则、activityId） |
| `src/core/methods.ts` | `dsh/src/bridge/index.ts` | 方法表校验规则逐条对齐（MALFORMED 语义、afterSeq 三态、幂等、push 兼容应答） |
| `src/core/stats.ts` | `dsh` 投影键集 | 「缺失≠零」规则；cacheHit 截断不四舍五入 |
| 黄金帧 | `protocol/fixtures/*.json` | 跨语言契约测试（TS + Swift 同读） |

**必须新写**（桌面端没有对应物）：会话存储（`session-store.ts`）、回合
运行器（`turn-runner.ts`）、引擎适配器（`engine/`）、工具沙箱（`tools.ts`）、
`kernel.*` 扩展面、JS 引擎宿主（`KernelRuntime.swift`）。

## 4. 并发模型（iOS 宿主）

- **一个 JSContext，一条串行队列**：所有 JS 触碰都经
  `performOnKernelQueue`；类 `@unchecked Sendable` 的安全性完全由这个
  漏斗保证。
- **慢活下队列**：fs/http 在并发队列执行，结果回内核队列再调 JS 回调；
  回调在 JS 线程上执行是铁律。
- **JSValue 跨闭关进 `JSBox`**（`@unchecked Sendable`）：契约是只在内核
  队列拆箱。Swift 6 严格并发下这是 JSValue 非 Sendable 的标准姿势。
- **微任务**：JSC 在原生调用的最外层入口退出时清微任务；宿主的每个
  队列块都是一次外层入口，回合链条因此自续（实测：一次 prompt 的整条
  记录链在毫秒级完成）。
- **平台怪癖备案**：对捕获类私有状态的函数直接 `.call` 会停摆；统一走
  `invokeMethod`（见 §2 决策 3）。

## 5. 测试策略（三层）

1. **TypeScript 单测**（`kernel/test/`，vitest，57 条）：帧信封、存储与
   崩溃规则、回合故事、方法校验、引擎 SSE 解析、投递记账、黄金帧契约。
2. **黄金帧契约**（`fixtures.test.ts`）：内核应答的结构键集与桌面端真实
   抓帧逐一对表（welcome/host-info/session-list/model-catalog/
   permissions-catalog/interactions-pending/error-frame + summary 白名单
   顺序）。iOS 的 `FixtureTests` 读同一批文件——「两个独立解码器读同一
   产物」是这个项目防漂移的机制。
3. **Swift 端到端**（`LocalKernelTests`，5 条）：真实 bundle 跑在
   JavaScriptCore 里，`MizarConnection`（未修改的客户端）经
   `LocalKernelTransport` 完成握手、完整回合（脚本化模型，不碰网络）、
   审批流、重启持久化、交互面。

## 6. 引擎适配指南

实现 `EngineAdapter`（`kernel/src/engine/types.ts`）：

```ts
interface EngineAdapter {
  readonly id: string
  runStep(request: {
    messages: EngineMessage[]        // 已从日志投影（system + 历史 + 工具结果）
    tools: EngineToolSpec[]          // 内置工具的 JSON Schema
    model: { provider, model, reasoningEffort? }
    onDelta(delta: { text?, reasoning? }): void
    signal: TurnSignal
  }): Promise<EngineStepResult>
}
```

- **一步一调用**：工具执行由回合运行器负责；适配器只把一步的结果交回来。
- **流式**：delta 在步骤完成前通过 `onDelta` 送达——它们被折叠进
  `assistant/attempt` 记录（activity 流的 `thinking` 行来源）。
- **取消**：`signal.aborted` 轮询 + `onAbort` 注册；中止的步骤返回
  `finishReason: "aborted"`。
- **错误**：`finishReason: "error"` + 稳定 `errorCode`
  （`MISSING_CREDENTIAL` 等已在 turn/end 语义里）。
- **usage**：能报就报（OpenAI `stream_options.include_usage` / DeepSeek
  尾块）；不能报就省略——stats 的「缺失≠零」规则会处理。

## 7. 已知取舍

- **会话日志全量驻内存**：单会话一个对话的量级（MB 内）；换来分页纯数组
  操作与精确游标。多 MB 会话出现时再加冷页换入换出。
- **每条记录一次 meta 写**：换来 `updatedAt`/`runningTurn` 的随时一致；
  量级无感。要省可改为节流。
- **单 JS 引擎单内核**：一个 App 内一个内核实例；多内核并存未设计。
- **审批 fail-closed**：GUI 全断开时回合失败。这是照搬桌面端的刻意取舍
  （拒绝可恢复，挂死不可恢复），GUI 侧的对策是保持连接。
- **无 steer**：`mode: "steer"` 目前等同排队；真正注入运行中回合需要引擎
  适配器支持「插入消息」，OpenAI 兼容引擎做不到，留待有状态的引擎适配。
