# Mizar 本地内核 — 外部通信 API（协议 v1）

本地内核与 GUI 之间说的话。**这份文档是内核的完整对外契约**：GUI（iOS 现在、Android 将来）只通过本文描述的协议帧与内核通信，除此之外没有第二条路径。

内核说的是与桌面端宿主插件（`dsh-mizar`）**逐字节相同的 Mizar 协议 v1**——帧信封、方法表、错误码、分页语义、审批模型全部与桌面端一致，因此未修改的客户端连接层（iOS 的 `MizarConnection`）可以不加改动地在「远程桌面」与「本地内核」之间切换。本文只完整陈述内核侧行为；与桌面端共同的部分以 `dsh/docs/protocol-v1.md` 为权威源，差异在 §11 明确列出。

> 本文从代码读出并对照实现验证：`LocalKernel/kernel/src/`（TypeScript 内核）、
> `MizarKit/Sources/MizarKit/Kernel/`（Swift 宿主与传输）。黄金帧契约测试
> （`LocalKernel/kernel/test/fixtures.test.ts`）与 Swift 端到端测试
> （`MizarKitTests/LocalKernelTests.swift`）共同钉住这些形状。

---

## 目录

1. [架构与嵌入模型](#1-架构与嵌入模型)
2. [连接生命周期与握手](#2-连接生命周期与握手)
3. [帧信封](#3-帧信封)
4. [错误码](#4-错误码)
5. [方法表（内核实现的 22 个方法 + 内核扩展）](#5-方法表)
6. [事件](#6-事件)
7. [会话记录与读取语义](#7-会话记录与读取语义)
8. [回合（turn）生命周期与记录序列](#8-回合生命周期与记录序列)
9. [权限模型与审批](#9-权限模型与审批)
10. [内核持久化布局](#10-内核持久化布局)
11. [与桌面端宿主的差异](#11-与桌面端宿主的差异)
12. [GUI 接入指南（iOS）](#12-gui-接入指南ios)
13. [GUI 接入指南（Android）](#13-gui-接入指南android)
14. [限制与已知边界](#14-限制与已知边界)

---

## 1. 架构与嵌入模型

```
┌───────────────────────────── 手机 / 平板 ─────────────────────────────┐
│                                                                       │
│  GUI（SwiftUI / Compose）                                             │
│      │  只说协议帧（JSON 文本）                                        │
│  ┌───▼────────────────────────┐                                       │
│  │ 客户端连接层                │  iOS: MizarConnection（不改动）        │
│  │ (握手/关联/事件流/重连)     │  Android: mizarkit MizarConnection     │
│  └───▼────────────────────────┘                                       │
│      │  WebSocketTransport 接口（四方法）                              │
│  ┌───▼───────────────┐                                                │
│  │ 传输适配           │  iOS: LocalKernelTransport（进程内）            │
│  └───▼───────────────┘  Android: 引擎宿主 + 进程内/回环传输             │
│  ┌───▼────────────────────────────────────────────┐                   │
│  │ 本地内核（TypeScript，平台中立）                  │                   │
│  │  协议帧 · 方法表 · 会话存储 · 回合运行器          │                   │
│  │  审批交互 · 模型目录 · 权限门控 · 引擎适配器      │                   │
│  └───▼────────────────────────────────────────────┘                   │
│      │  PlatformHost（平台注入：fs / http / kv / 定时器 / uuid）        │
│  ┌───▼──────────────┐                                                 │
│  │ JS 引擎           │  iOS: JavaScriptCore  Android: JSC/QuickJS 等   │
│  └──────────────────┘                                                 │
└───────────────────────────────────────────────────────────────────────┘
```

三条解耦边界，每条都只有一种通信方式：

1. **GUI ↔ 内核：协议帧。** JSON 文本帧，进程内传递（iOS 经
   `LocalKernelTransport`，它实现 `WebSocketTransport` 四方法接口）。GUI 不知道
   对端是 JS 引擎还是远程机器；内核不知道 GUI 是 SwiftUI 还是 Compose。
2. **内核 ↔ 平台：`PlatformHost`。** 内核是平台中立 TypeScript，所有
   平台能力（文件、HTTP、键值存储、定时器、uuid、日志）由嵌入方注入
   一个回调风格的对象。Android 宿主实现同一接口即可复用整个内核。
3. **内核 ↔ 引擎：`EngineAdapter`。** 回合运行器只要求引擎「输入消息列表
   与工具表，流式吐出增量与工具调用」。默认实现是 OpenAI 兼容流式引擎；
   将来接入其他引擎只需实现此接口。

**嵌入入口**（iOS，Swift）：

```swift
let runtime = KernelRuntime(rootURL: root, hostName: deviceName)   // 持有 JS 引擎
try await runtime.boot()                                           // 加载内核 bundle
let transport = LocalKernelTransport(runtime: runtime)             // 进程内传输
let connection = MizarConnection(
    configuration: .init(authority: "127.0.0.1:19390", token: "local"),
    makeTransport: { transport },
)
let welcome = try await connection.connect()   // 与远程主机完全相同的握手
```

`KernelRuntime` 的 Swift API：

| 成员 | 说明 |
|---|---|
| `init(rootURL:hostName:kv:httpHandler:)` | root 为内核沙盒根目录；`kv` 默认 UserDefaults（可换 Keychain）；`httpHandler` 默认 URLSession 流式实现（测试注入脚本化实现） |
| `boot() async throws` | 求值内核 bundle、创建内核、装载会话 |
| `openConnection() async throws -> KernelSocket` | 打开一条客户端连接 |
| `rootURL` / `home` / `hostName` | 沙盒根、展示路径（welcome 的 `home`）、内核名 |

---

## 2. 连接生命周期与握手

连接是**协议意义上的 socket**：文本帧进、文本帧出。进程内传输与回环
WebSocket 在协议层不可区分。

**握手规则**（与桌面端一致）：

1. 连接后的**第一帧必须是 `hello`**；其他任何帧回答
   `UNAUTHENTICATED` 错误帧，连接不断开。
2. `hello` 的 `token` 内核**接受任意值**（包括空串）：本地内核没有配对
   概念。字段保留是为了让客户端的 hello 帧不需要任何修改。
3. 内核以 `welcome` 帧应答（**不带 `id`**，即使 hello 带了）：

```jsonc
{
  "v": 1, "type": "welcome",
  "hostId": "uuid",            // 内核首次 boot 时生成，持久于 kv
  "hostName": "Shirazu 的 iPhone",
  "protocolVersion": 1,
  "home": "/…/LocalKernel",    // 内核根的展示路径
  "deviceId": "uuid"           // 内核生成的设备 id（本地只有一个）
}
```

4. **重复 hello 无害**：再次回答 welcome。
5. 握手前发请求：`UNAUTHENTICATED`。
6. **信封级畸形帧不拆连接**：`MALFORMED_FRAME` / 版本不符以错误帧回答后
   连接继续可用（与桌面 listener 一致）。

**hello 帧字段**：`v: 1`、`type: "hello"`、`token: string`（任意）、
可选 `id`、`appVersion`、`deviceModel`、`protocolVersion`（用于日志与
精确报错；版本不一致由客户端自行检测——welcome 永远是 v1）。

---

## 3. 帧信封

五种帧，全部带 `v`。客户端 → 内核两种，内核 → 客户端四种。

### 客户端 → 内核

```jsonc
// 握手（必须是第一帧）
{ "v": 1, "type": "hello", "id": "h1", "token": "…",
  "appVersion": "1.0", "protocolVersion": 1, "deviceModel": "iPhone" }

// 方法调用（payload 可省略）
{ "v": 1, "id": "m1", "type": "session.list", "payload": { … } }
```

- `id` 由客户端生成，内核的 ok/error 回帧**原样带回**。
- `type` 是方法名；未知方法回答 `NOT_IMPLEMENTED`（不是错误，是能力
  协商信号）。
- `payload` 形状由各方法自行校验；**payload 整体必须是对象**（缺省视为
  `{}`），字段类型错误一律 `MALFORMED_FRAME`，绝不静默取默认值。

### 内核 → 客户端

```jsonc
{ "v": 1, "type": "welcome", "hostId": "…", "hostName": "…",
  "protocolVersion": 1, "home": "…", "deviceId": "…" }        // 仅握手应答

{ "v": 1, "type": "ok", "id": "m1", "result": { … } }          // result 可省略

{ "v": 1, "type": "error", "id": "m1", "code": "MALFORMED_FRAME",
  "message": "…", "retryable": false }                          // id 可省略（主动失败）

{ "v": 1, "type": "event", "event": "interactions.changed",
  "data": { "approvals": 1, "questions": 0 } }                  // 主动推送，无 id
```

**事件帧是尽力而为的**：帧发送失败绝不影响产生它的状态变更。审批卡片
仍然在 `interactions.pending` 里，客户端的 45 秒兜底轮询是最后保险。

---

## 4. 错误码

客户端**必须按 `code` 分支，不能匹配 message 文本**。内核使用与桌面端
相同的错误码表（23 个）；内核实际发出的码如下：

| code | 内核何时发出 | retryable |
|---|---|---|
| `PROTOCOL_VERSION_MISMATCH` | 帧的 `v` 不是 1 | 否 |
| `MALFORMED_FRAME` | 帧缺 type/id、payload 不是对象、字段类型不符（各方法列出自己的规则） | 否 |
| `UNAUTHENTICATED` | 握手前发请求 | 否 |
| `RATE_LIMITED` | （保留；内核当前不限流） | — |
| `WRITER_HELD` | （保留；本地内核单写者，不会出现） | — |
| `MODEL_UNAVAILABLE` | 请求的 provider/model 不在目录中；`kernel.apiKey.set` 的 provider 不存在 | 否 |
| `REMOTE_ERROR` | 引擎/存储层失败的原样转发：会话不存在、未知权限预设、归档被拒等 | 视情况 |
| `NOT_IMPLEMENTED` | 未知方法；`upload.begin/chunk/finish/abort`；带附件的 `session.prompt` | 否 |
| `INTERNAL` | 内核内部错误（bug，请报告） | 否 |
| `RESPONSE_TOO_LARGE` | （保留；内核以 256 KiB 页预算自我限制，正常不触发） | — |

upload/attachment 段（`UPLOAD_*` / `ATTACHMENT_*`）与 `PAIRING_*`、
`DEVICE_REVOKED` 保留在码表中以维持与桌面端的表一致；客户端对未知码的
容错模型（`MizarError.known == nil`）不受影响。

错误 message 是**日志与工单用语**，不是 UI 文案；UI 按 code 取本地化文案。

---

## 5. 方法表

内核实现以下方法。标注「桌面端共有」的与 `dsh-mizar` 方法语义逐字对齐；
「内核扩展」是本地内核独有面（桌面端对未知方法回 `NOT_IMPLEMENTED`，
所以老客户端不受影响）。

### 5.1 主机与会话（桌面端共有）

#### `ping` → `{ pong: true }`

#### `host.info` → `{ hostId, hostName, home, protocolVersion }`

不含桌面端的可选 `addresses` 字段：本地内核没有可拨地址。

#### `session.list` → `{ items: SessionRow[] }`

按 `updatedAt` 降序。**已归档会话不出现**。每行：

```jsonc
{ "sessionId": "session-…", "updatedAt": 179…, "running": false,
  "blank": false, "agentAvailable": true, "cwd": "/…/workspace/session-…",
  "parentSessionId": null, "origin": null }
```

`cwd` 是内核为该会话分配的沙盒工作区的**展示路径**
（`<home>/workspace/<sessionId>`）。`parentSessionId` / `origin` 保留
`null`（子代理是后续能力）。

#### `workspace.list` → `{ items: [WorkspaceRow], complete: true }`

内核只有一个工作区根，`workspaceId` 固定 `"kernel"`：

```jsonc
{ "items": [{ "workspaceId": "kernel", "name": "Local workspace",
              "path": "<home>/workspace",
              "sessionIds": ["session-…", …] }],
  "complete": true }
```

#### `session.create` → `{ sessionId, agentPreset }`

payload（全部可选）：

| 字段 | 规则 |
|---|---|
| `cwd` | **必须**是内核工作区根（`<home>/workspace`）或省略。传其他值回答 `REMOTE_ERROR`——本地内核自管沙盒，不承诺一个文件工具摸不到的目录 |
| `sessionId` | 恢复指定 id 的会话；不安全 id（非 `[A-Za-z0-9_-]`）回答 `MALFORMED_FRAME`；已存在回答 `REMOTE_ERROR` |
| `agentPreset` | 原样记录并回显（v0 不改变行为） |

创建时内核同时建立两件事：会话目录 `sessions/<id>/` 与
**会话工作区 `workspace/<id>/`**——工作区从出生就存在，工具第一步
`list_dir` 看到的是空目录而不是「目录不存在」。

#### `session.prompt` → `{ accepted: true, requestId }`

| 字段 | 规则 |
|---|---|
| `sessionId` | 必填，非空字符串 |
| `text` | 必填（有附件时可省——但内核 v0 不支持附件，见下） |
| `attachmentIds` | 传了且非空数组 → `NOT_IMPLEMENTED`（v0 无附件）；空数组可传 |
| `mode` | `"queue"` 或 `"steer"`；两者在本地内核里行为相同（都排队），其他值 `MALFORMED_FRAME` |
| `requestId` | **幂等键**。客户端重试同一 prompt 必须复用同一 `requestId`；新消息必须用新值。缺省时内核生成 |
| `clientTimeZone` | 原样记录（v0 不改变行为） |

**prompt 永远立即返回**，回合在后台跑；进度通过轮询
`session.messages` / `session.activity` 读取（与桌面端完全相同的模式）。

**回合已在运行时**，prompt 进入该会话的队列，当前回合结束后依次执行
（`mode: "steer"` 亦排队——内核 v0 不支持注入运行中的回合）。

#### `session.cancel` → `{ accepted: true }`

取消该会话**正在运行**的回合（以及队列中待执行的回合？——不：只取消
当前回合；队列保留）。回合以 `reason.kind: "stopped"` 收尾。没有运行中
回合时同样回答 `{accepted: true}`。会话不存在回答 `REMOTE_ERROR`。

#### `session.messages` → `{ sessionId, asOfSeq, records[], hasMore }`

**只发总结，不发过程**（语义与桌面端逐字一致）：

| afterSeq | 客户端的意思 | 内核的行为 |
|---|---|---|
| 数字 | 该位置及之前我都有 | 只回 `seq` 更大的总结记录 |
| `null` | 我什么都没有 | 回完整总结尾页，不参考投递记账 |
| 缺省 | 未声明 | 用**投递记账**（见下）已成功送达这台设备的位置 |

- `beforeSeq`（可选，数字）：向后翻页，读该位置之前的窗口；与 `afterSeq`
  同时出现时 `afterSeq` 失效。
- `maxMessages`（可选）：原始记录窗口上限（缺省 400）。
- 总结白名单（**对增量页同样生效**）：`turn/start`、`turn/end`、
  `step/start`、`user/message`、每轮**最后一条有正文的** `assistant/message`
  （且该轮已在页内结束）。工具调用、叙述、未结束轮的中间回复**不发**——
  过程细节走 `session.activity`。
- 过滤顺序：先总结、再按 `afterSeq` 过滤、最后按字节预算裁剪（保最新）。
- **字节预算 256 KiB**：超预算从旧端裁剪，至少保留一条；单条超预算的
  记录仍然放行（空页比超页更糟）。
- `asOfSeq`：读取时刻的日志切点（`meta.lastSeq`）；未知会话返回
  `{sessionId, asOfSeq: null, records: [], hasMore: false}`——**不是错误**
  （与桌面端一致：客户端与归档竞争时不应看到失败）。
- `hasMore`：窗口之下是否还有更旧的记录（向后翻页用）。

**投递记账**：一页 `ok` 帧**真正写出之后**，本页最大 `seq` 才记入该
`deviceId + sessionId` 的账。被拒、断连的页不算送达，下次（缺省
`afterSeq` 的）读取会重新提供。

#### `session.activity` → `{ sessionId, asOfSeq, turn, entries[], hasMore, oldestSeq }`

**只回答正在跑的那一轮**（付费「全量细节」的同源语义）：

- 正在跑的轮次 = 页内**有活动且没有 `turn/end` 的最大轮号**（页窗口可以从
  轮中间开始，缺 `turn/start` 不算没在跑）。
- `entries[]` 每行：`{ id, seq, at, kind, title, text }`：
  - `id`：`seq-<n>`（有日志位置时）或 `at-<time>-<kind>`；客户端按 id
    跨轮询合并。
  - `kind`：`thinking`（来自 `assistant/attempt` 的流块）、`command`
    （shell 类工具名，本地内核暂无）、`tool`（其他工具调用）、`output`
    （工具结果）。
  - `text`：**压平成一行、截断 240 字符**；`title` 截断 120。
- 上限：`maxEntries` 缺省 200、**封顶 300**；整体 JSON 预算 256 KiB
  （超限保最新行）。
- 向后翻页：`beforeSeq` + `turn` **必须同时出现**（`beforeSeq` 不带
  `turn` → `MALFORMED_FRAME`；`turn` 不带 `beforeSeq` 被忽略）。向后读
  只保留该轮次的行；`hasMore` = 行被裁剪 ∨（页有更旧记录 ∧ 本页含该轮
  的行）——第二个条件为假说明已翻过轮次开头，必须停。
- `turn: null, entries: []` 不是错误：两轮之间、会话不存在都这样答。
- 纯读：不唤醒引擎、不改状态。

#### `session.stats` → `{ sessionId, asOfSeq, stats }`

**缺失的键 ≠ 零**：客户端必须把新帧**合并**进旧帧。内核报告它实际测得的：

```jsonc
{ "sessionId": "…", "asOfSeq": 12,
  "stats": {
    "tokenUsage": {                       // 引擎上报过 usage 才出现
      "uncachedInputTokens": 0, "outputTokens": 22,
      "cacheReadTokens": 0, "cacheWriteTokens": 0,
      "billedInputTokens": 0 },
    "cacheHit": { "ratio": null, "displayPercent": "0%" },  // 截断，永不四舍五入到 100%
    "stats": { "turns": 1, "steps": 1, "llmMs": 915, "toolMs": 0,
               "ttftMs": null, "decodeTokensPerSecond": null },
    "model": { "lastUsed": {…}, "next": {…} },
    "permissionPreset": "workspace-write",   // 设置过才出现
    "title": "…"                             // 改名过才出现
  } }
```

`context`（上下文占用）**整个省略**：内核 v0 不测量上下文压力，伪造一个
窗口占用比缺字段更糟。会话不存在回答 `REMOTE_ERROR`。

#### `session.rename` → `{ renamed: true }`

`{sessionId, title}`；title 必须是非空字符串。

#### `session.archive` → `{ archived: true }`

| 字段 | 规则 |
|---|---|
| `sessionId` | 必填 |
| `stopActivity` | 可选布尔；传了非布尔 → `MALFORMED_FRAME`（改状态的调用必须把客户端 bug 报出来） |

回合仍在跑且未传 `stopActivity` → `REMOTE_ERROR`（**绝不偷偷停**）。
`stopActivity: true` → 先取消回合再归档。归档**非破坏性**：日志留在磁盘，
`session.list` / `workspace.list` 不再出现；投递记账遗忘该会话。

### 5.2 模型与权限（桌面端共有）

#### `model.catalog` → `{ default, providers[], failures: [] }`

形状与桌面端 fixture 一致。目录来自内核配置（默认编译进内核，`config.json`
或 `kernel.config.set` 可覆盖）：

```jsonc
{ "default": { "provider": "deepseek-official", "model": "deepseek-chat",
               "reasoningEffort": "off" },
  "providers": [
    { "id": "deepseek-official", "name": "DeepSeek",
      "models": [
        { "id": "deepseek-chat", "name": "DeepSeek Chat",
          "efforts": [{ "id": "off", "name": "Off", "description": "…" }],
          "defaultEffort": "off" },
        { "id": "deepseek-reasoner", "name": "DeepSeek Reasoner", … } ] } ],
  "failures": [] }
```

#### `session.model.set` → `{ sessionId, selected }`

`{sessionId, provider, model, reasoningEffort?}`。provider/model 不在目录
→ `MODEL_UNAVAILABLE`。`reasoningEffort` 省略时取模型 `defaultEffort`。

#### `permissions.catalog` → `{ options[], defaults[], defaultPreset }`

三个预设：`read-only` / `workspace-write` / `danger-full-access`，
`defaultPreset: "workspace-write"`。与桌面端 fixture 逐字一致。

#### `session.permission.set` → `{ commandResult: { preset } }`

`{sessionId, preset}`。未知预设回答 `REMOTE_ERROR`，message 与桌面端
黄金帧同款：`unknown preset "…" (available: read-only, workspace-write,
danger-full-access)`。

### 5.3 交互（桌面端共有）

#### `interactions.pending` → `{ approvals[], questions[] }`

```jsonc
// PendingApprovalView
{ "requestId": "ap-…", "sessionId": "…", "toolName": "write_file",
  "callId": "call-…", "reason": "…", "displayReason": null,
  "requestedAt": 179… }

// PendingQuestionView
{ "callId": "…", "sessionId": "…",
  "questions": [{ "id": "q1", "question": "…", "detail": "…", "header": "…",
                  "options": [{ "label": "…", "description": "…" }],
                  "multiSelect": false, "intent": null }],
  "requestedAt": 179… }
```

#### `approval.answer` → `{ accepted: true }`

`{requestId, outcome, by?}`。**outcome 只有两个合法值**：`allowed-once`
与 `rejected`；其他值 `MALFORMED_FRAME`（没有 always-allow——见 §9）。
重复回答同一 `requestId` 是无害的 no-op（第一次已结算）。

#### `question.answer` → `{ accepted: true }`

`{callId, answers: [{ id, selected: string[], custom? }]}`。内核校验：每题
恰好被回答一次（多答、漏答 → `MALFORMED_FRAME`）；批次已消失时照常回答
`{accepted: true}`（no-op，与桌面端一致）。

### 5.4 通知（桌面端共有，内核兼容应答）

本地内核没有推送通道，但三个方法**照常应答**，让客户端不必知道连的是
哪种宿主：

| 方法 | 校验 | 应答 |
|---|---|---|
| `push.register` | `token` 必填非空；`platform` 缺省 `ios`，只接受 `ios`/`android`（大小写敏感）；iOS 时 `environment` 必填 `sandbox`/`production`；`liveActivityToken` 须为 1–200 位小写十六进制 | `{ registered: false }` |
| `push.presence` | `foreground` 必须是布尔 | `{ accepted: true }` |
| `push.unregister` | — | `{ unregistered: true }` |

校验规则与桌面端逐条一致：客户端 bug 必须报出来，哪怕注册本身是 no-op。

### 5.5 附件上传（桌面端共有，内核未实现）

`upload.begin` / `upload.chunk` / `upload.finish` / `upload.abort` 一律
回答 **`NOT_IMPLEMENTED`**；`session.prompt` 带非空 `attachmentIds` 同样。
这是客户端判断「这台宿主不支持附件」的标准信号（桌面端协议原文如此）。

### 5.6 内核扩展命名空间（本地内核独有）

以下方法属于本地内核。GUI 的设置界面建立在这组方法上；桌面端宿主对它们
回 `NOT_IMPLEMENTED`，客户端据此可判断宿主类型。

#### `kernel.status` → `{ kernelVersion, protocolVersion, engine, hostId, home, sessions }`

#### `kernel.config.get` → `{ config }`

返回完整运行配置（providers / defaultModel / contextWindow /
systemPromptAddendum / defaultPreset）。**不含任何凭据**。

#### `kernel.config.set` → `{ config }`

payload 携带要覆盖的字段（providers 数组整体替换；标量按字段替换）：

```jsonc
{ "providers": [ { "id": "my-gateway", "name": "My Gateway",
                   "baseUrl": "https://my.host/v1", "path": "/chat/completions",
                   "usage": true,
                   "models": [{ "id": "m1", "name": "Model One" }] } ],
  "defaultModel": { "provider": "my-gateway", "model": "m1" },
  "contextWindow": 128000,
  "systemPromptAddendum": "额外系统提示词",
  "defaultPreset": "workspace-write" }
```

未命名字段保留原值；写入持久化到 `<root>/config.json`。**至少命名一个
已知字段**，否则 `MALFORMED_FRAME`。

#### `kernel.apiKey.set` → `{ set: true }`

`{provider, key}`。provider 必须在目录中（否则 `MODEL_UNAVAILABLE`）。凭据
写入平台键值存储（iOS 默认 UserDefaults，键 `mizar.kernel.apiKey.<provider>`；
可换 Keychain 实现）。**任何读取面都不回显凭据**。

#### `kernel.apiKey.clear` → `{ cleared: true }`

`{provider}`。

#### `kernel.apiKey.status` → `{ providers: [{ id, name, hasKey }] }`

只有布尔，没有值。

**引擎对凭据的行为**：引擎调用前读取 `apiKey.<provider>`；缺失时该步以
`finishReason: "error"`、`errorCode: "MISSING_CREDENTIAL"` 结束——回合以
`turn/end { reason: { kind: "error", error: { code: "MISSING_CREDENTIAL",
message: "no API key for provider …" } } }` 收尾，GUI 据此引导用户去设置。

---

## 6. 事件

内核主动推 `event` 帧。**只推交互一族**（与三家桌面宿主的既成事实一致）；
会话内容更新不推送，客户端用 `session.messages(afterSeq)` 增量拉取。

| event | 何时发 | data |
|---|---|---|
| `interactions.changed` | 待处理集合有任何变化 | `{ approvals: n, questions: n }` —— **只带计数**，通知不会过期；客户端收到后重拉 `interactions.pending` |
| `approval.request` | 一个新审批 | `PendingApprovalView` |
| `approval.resolved` | 审批被回答或撤回 | `{ requestId, outcome, by? }`；outcome ∈ `allowed-once` / `rejected` / `cancelled` / `unavailable` |
| `question.request` | 一个提问批次 | `PendingQuestionView` |
| `question.resolved` | 提问被回答或撤回 | `{ callId }` |

**fail-closed 规则**：最后一个客户端断开时，所有待处理审批结算为
`unavailable`、所有提问批次结算为空——被拒绝的工具动作可以重来，永远
等一张没人看得见的卡片不行。单客户端 GUI 的含义：**GUI 断开（进后台被
挂起不算，进程被杀才算）时运行中的回合会因审批拿不到回答而以
`PERMISSION_UNAVAILABLE` 失败**。GUI 应保持连接或接受该语义。

---

## 7. 会话记录与读取语义

### 7.1 记录形状

`session.messages` 返回的每条记录是网关包装形：

```jsonc
{ "type": "event",
  "event": { "type": "user/message", "seq": 8, "time": 1791984791224,
             "data": { … } } }
```

- `seq`：会话日志内单调序号，翻页游标，**追加稳定、跨重启稳定**。
- `time`：**epoch 毫秒**。
- 记录**原样透传、不归一化**（协议第一规则）：事件名集合是开放的，客户端
  决定认识什么，不认识的照样显示。

### 7.2 内核发出的事件类型（回合日志）

| type | data | 出现时机 |
|---|---|---|
| `turn/start` | `{ turn }` | 回合开始 |
| `step/start` | `{ turn, step }` | 每个引擎步骤开始 |
| `user/message` | `{ content: [{type:"text",text}], source: {kind:"user", rpcId}, role: "user", id }` | 第一步内、step/start 之后（与桌面端日志顺序一致） |
| `assistant/attempt` | `{ turn, step, attempt, stream: [{type:"text-chunks"\|"reasoning-chunks", texts:[…]}] }` | 每步流式增量的持久化折叠 |
| `assistant/message` | `{ turn, step, message: { role: "assistant", content: [{type:"text",text}] } }` | 每步最终文本 |
| `tool/call` | `{ turn, step, callId, name, arguments }` | `arguments` 是 JSON 字符串（桌面端日志同形） |
| `tool/result` | `{ turn, step, callId, name, output }` 或 `{ …, error: { code, message } }` | 工具执行后 |
| `turn/end` | `{ turn, reason: { kind: "completed"\|"stopped"\|"error", error? } }` | 唯一结束一轮的记录 |

`reason.kind` 三态：`completed`（自然完成）、`stopped`（客户端取消、
`stopActivity` 归档、内核重启闭合）、`error`（`error.code`：
`MISSING_CREDENTIAL` / `MODEL_UNAVAILABLE` / `REMOTE_ERROR` / `STEP_LIMIT`
（32 步上限）/ `INTERNAL`）。

**以 error 结束的轮次没有产出回答**，GUI 必须显式呈现而不是当作空回复。

### 7.3 附件占位

内核 v0 无附件，`[Photo]` / `[File: name]` 占位规则不触发（桌面端
`session.messages` 唯一会改写记录的地方）。

---

## 8. 回合生命周期与记录序列

一次 prompt 的完整记录序列（GUI 渲染与测试的权威顺序）：

```
turn/start {turn}
step/start {turn, step:1}
user/message {content, source:{kind:"user", rpcId}, role:"user", id}
  ├──（引擎流式增量）
assistant/attempt {turn, step, attempt:1, stream:[…]}
assistant/message {turn, step, message}          ← 步骤有正文才有
  ├──（模型请求工具时）
tool/call {turn, step, callId, name, arguments}
tool/result {turn, step, callId, name, output|error}
  ├──（有工具调用 → 下一轮引擎调用）
step/start {turn, step:2}
…
turn/end {turn, reason}
```

- 工具调用是**引擎闭环**的一部分：拒绝/失败的结果会作为 `tool/result`
  交回引擎，引擎可以换路重试。
- 步数上限 **32**；超过以 `STEP_LIMIT` 错误收尾。
- **崩溃语义**：内核重启时，日志里未闭合的回合由启动扫描补一条
  `turn/end {reason:{kind:"stopped"}}`——回合确实停了；假装还在跑会让
  客户端的「工作中」状态永远挂起。尾行撕裂（崩溃时的半行）跳过，不拖垮
  会话。
- **幂等**：同一 `requestId` 的重复 prompt 不会插入第二条用户消息。

---

## 9. 权限模型与审批

### 9.1 预设覆盖范围

| 动作 | read-only | workspace-write | danger-full-access |
|---|---|---|---|
| `list_dir` / `read_file` | ✓ | ✓ | ✓ |
| `write_file`（工作区内） | ✗ 审批 | ✓ | ✓ |
| `write_file`（工作区外、内核根内） | ✗ 审批 | ✗ 审批 | ✓ |
| `web_fetch` | ✗ 审批 | ✗ 审批 | ✓ |
| `ask_user_question` | ✓（不经门控） | ✓ | ✓ |

- 工具路径**相对会话工作区**解析；绝对路径与越出允许根的 `..` 被**拒绝**
  （`PATH_ESCAPES_SANDBOX`），绝不静默改写。
- **审批是 `allowed-once`**：只覆盖发起它的那一次调用。**刻意没有
  always-allow**——活得比请求久的许可是权限变更，应走
  `session.permission.set`（可见、可撤销）。
- `rejected` / `cancelled` / `unavailable` 都以
  `PERMISSION_DENIED` / `PERMISSION_UNAVAILABLE` 结果交回引擎。
- 门控发生在 `tool/call` 记录**之前**：未经许可的调用不会被记成执行过——
  拒绝作为该调用的结果出现在日志里。

### 9.2 内置工具

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_dir` | `path?`（缺省 `"."`） | 列工作区目录 |
| `read_file` | `path` | 读 UTF-8 文本，200 K 字符截断并注明 |
| `write_file` | `path, content` | 写/覆盖，建父目录 |
| `web_fetch` | `url` | GET http(s)，正文前 64 KB，30 s 超时；只读、不执行脚本 |
| `ask_user_question` | `questions: [{question, detail?, header?, options?, multiSelect?}]`（≤4 题） | 经审批交互通道问操作者；等待回答；撤回答 `UNANSWERED` |

手机上**没有 shell**——桌面端的 `shell`/`exec` 词汇不出现。工具表的
JSON Schema 会完整发给引擎；GUI 无需感知工具细节（活动流的
`tool/call` 行有名字与一行参数摘要）。

---

## 10. 内核持久化布局

```
<root>/                              ← KernelRuntime(rootURL:)
  config.json                        ← kernel.config.set 的持久化
  sessions/<sessionId>/
    meta.json                        ← 标题/cwd/模型/预设/游标/usage/计时
    log.jsonl                        ← 记录日志（追加写，每行一条 JSON）
  workspace/<sessionId>/             ← 该会话的工具沙盒（出生即存在）
```

- **记录日志是写前真相**：每条记录先落 `log.jsonl` 再可读；内存中的解析
  副本让分页是纯数组操作。
- `meta.json` 记录 `runningTurn`：重启时若有未闭合回合，补 `turn/end
  stopped`（见 §8）。
- 平台键值存储（UserDefaults / Keychain / 宿主自选）存：`kernel.hostId`、
  `kernel.deviceId`、`apiKey.<provider>`、`config.json` 之外的配置不在
  kv。

---

## 11. 与桌面端宿主的差异

| 面 | 桌面端（dsh-mizar） | 本地内核 |
|---|---|---|
| 传输 | WebSocket `/mizar/v1/ws`（LAN/中继） | 进程内通道（协议同形；路径/端口无意义） |
| 配对 | `hello`/`pair` HTTP + 设备令牌 | 无；token 任意 |
| 附件 | `upload.*` 四步 + prompt 附件 | `NOT_IMPLEMENTED` |
| 推送 | 中继投递 APNs/FCM + Live Activity | 兼容应答 `{registered:false}` |
| 引擎 | DSH 网关（Typert 协议投影） | `EngineAdapter`（默认 OpenAI 兼容流式） |
| 会话存储 | DSH 上游投影服务 | 内核自带（JSONL + meta） |
| `session.activity` | 付费账户语义 | 相同实现，是否轮询由客户端决定 |
| 子代理 | `parentSessionId`/`origin` | 恒 `null`（后续能力） |
| `WRITER_HELD` | 桌面 UI 占用时 | 不会出现（单写者） |

错误码表、帧信封、summary/activity/stats 语义、审批模型、幂等规则、
预算数值（256 KiB / 200+300 条 / 240+120 字符）**全部一致**。

---

## 12. GUI 接入指南（iOS）

接缝已存在并经测试验证（`MizarKitTests/LocalKernelTests.swift`）：

1. **创建内核**（App 启动或进入本地模式时）：

```swift
let root = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask,
         appropriateFor: nil, create: true)
    .appendingPathComponent("LocalKernel", isDirectory: true)
let runtime = KernelRuntime(rootURL: root, hostName: UIDevice.current.name)
try await runtime.boot()
```

2. **把它变成一个「宿主」**：本地内核不需要配对。给 `PairedHost`
   增加一种来源（如 `.local`），或直接在 `AppModel.makeConnection` 的
   `makeTransport` 处按宿主类型选择传输：

```swift
// MizarConnection 不经修改——本地与远程只是 transport 不同：
MizarConnection(
    configuration: .init(authority: "local", token: ""),
    makeTransport: { LocalKernelTransport(runtime: runtime) },
)
```

`LocalKernelTransport` 实现 `WebSocketTransport` 四方法（connect/send/
receive/close），`connect` 的 url/headers 被接受并忽略。

3. **GUI 侧需要的增量 UI**（后续工作）：
   - 宿主列表里的「本地内核」入口（不需要配对流程，直接建连接）；
   - 设置页：`kernel.apiKey.set/status`（API Key）、
     `kernel.config.get/set`（模型与预设）、`permissions.catalog` +
     `session.permission.set`（会话权限）；
   - 审批/提问卡片、会话详情、运行细节——**现有界面已按协议渲染，
     无需改动**。

4. **测试**：`scripts/swift.sh test` 中的 `LocalKernelTests` 覆盖
   握手、完整回合、审批流、重启持久化、交互面——全部走真实 bundle
   + 脚本化模型，不碰网络。

---

## 13. GUI 接入指南（Android）

内核是平台中立 TypeScript（`LocalKernel/kernel/dist/mizar-kernel.js`，
52 KB IIFE，暴露 `globalThis.MizarKernel.createKernel({host})`）。Android
宿主要做的：

1. **嵌入一个 JS 引擎**（QuickJS-Android / JSC 移植 / Hermes 均可；
   要求 ES2020 + Promise）。宿主需要提供的能力与 iOS 完全相同，即
   `PlatformHost` 形状（见 `kernel/src/host/host.ts` 注释）：

```ts
host = {
  hostName, home, platformVersion,
  fs: { readText(path, cb), writeText(path, data, cb), appendText(path, data, cb),
        deletePath(path, cb), listDir(path, cb), makeDir(path, cb) },   // 路径相对沙盒根
  http: { request(req, {onChunk, onDone, onError}) → {abort} },          // 流式、行粒度
  kv: { get(key, cb), set(key, value, cb), delete(key, cb) },
  log(level, message), uuid(), now(),
  setTimeout(fn, ms), clearTimeout(handle),
}
```

   回调风格是有意的：桥上不构造 Promise 对象（每个引擎做法不同），
   内核在纯 JS 里自行包装（`fromCallback`）。

2. **传输**：实现 `WebSocketTransport` 等价接口（connect/send/receive/
   close 四方法），内部把帧交给 `kernel.openConnection()` 返回的 socket
   对象（`send(text)` / `onFrame(cb)` / `close()`）。参照
   `MizarKit/Sources/MizarKit/Kernel/LocalKernelTransport.swift`，那份
   实现只有 40 行。

3. **协程/线程**：JS 引擎单线程即可；宿主回调（fs/http/kv）在后台线程
   执行慢操作，**回到 JS 线程再调用回调**（iOS 宿主的铁律，Android 相同）。

4. **契约测试**：把 `LocalKernel/kernel/test/` 移植为引擎内测试
   （vitest → 任意 runner），至少保留 `fixtures.test.ts`——它与 iOS 的
   `FixtureTests` 读同一批 `protocol/fixtures/*.json`，三方共享同一字节
   是这个项目契约不漂移的机制。

---

## 14. 限制与已知边界

- **附件**：无上传、无图片输入。协议面已预留（`NOT_IMPLEMENTED` 信号 +
  prompt 的 `attachmentIds` 校验），实现在 `upload.*` 存储落内核沙盒即可。
- **推送 / Live Activity**：本地内核永远 `{registered: false}`。
- **子代理**：`parentSessionId` / `origin` 恒 null。
- **上下文压力**：`session.stats` 无 `context` 字段（诚实缺失）。
- **多窗口**：内核支持多条并发连接（iPad + iPhone 同机场景），但最后一条
  断开即 fail-closed（见 §6）。
- **单引擎**：v0 只带 OpenAI 兼容适配器；`EngineAdapter` 是唯一需要实现
  的扩展点（见 `kernel/src/engine/types.ts` 注释，内含 Claude Code /
  Codex 适配的指引）。
- **性能**：回合的每次记录追加 = 一次文件 append + 一次 meta 写；手机
  闪存上单轮 ~10 条记录的量级完全无感。会话日志全量驻内存（单会话一个
  对话的量级，MB 级以内）。
- **JavaScriptCore 嵌入的已知怪癖**：从原生侧对「闭包捕获私有类状态的
  函数」直接 `.call` 在该平台会停摆；宿主一律以 `invokeMethod` 在**对象
  上**调用回调（iOS 宿主已如此，Android 宿主注意同样的坑）。
