# DSH-Mizar iOS 推送点击闪退 — 排查与修复报告

日期：2026-10-21 · 代码基线：iOS `16a1834`（HEAD）+ 工作区未提交改动

> 注意：本工作区当前有另一项进行中的大改动（登录门禁 / 积分 / 付费相关，
> 涉及 AppModel、RootView、AccountController 等）。本报告的三处修复只碰了
> `PushController.swift`、`RootView.swift`、`Conversation.swift`、`JSONValue.swift`
> 和测试文件，未触碰其余文件；全部改动未提交。

## 1. 结论概要

应用侧 Swift 代码在「点击推送 → 进入 app → 打开会话」这条路径上**防御性极好，
未找到必然触发崩溃的代码点**。已实证验证：打开一个**不存在/未同步的会话**
（推送点击会产生的数据形态）不会崩溃。

排查中发现 **3 个真实缺陷，全部已修复并验证**。其中 #1 是能造成闪退的候选，
但依赖宿主数据形态 —— 要 100% 确认是不是用户遇到的这一个，仍需要崩溃日志。

**定位闪退的最快路径**（若修复后仍复现）：TestFlight → App Store Connect → 崩溃
报告，或真机「设置 → 隐私 → 分析与改进 → 分析数据」里最近的 `DSH-Mizar-*.ips`。

## 2. 已完整审查并确认干净的路径

| 环节 | 文件 | 结论 |
|---|---|---|
| 推送到达（前台） | `PushController.swift` `willPresent` | 纯逻辑分类 + `AppSettings.shared.isEnabled`，无陷阱 |
| 推送点击 | `PushController.swift` `didReceive` | `userInfo["sessionId"] as? String` 对 null/缺失/非字符串全部安全 |
| 通知转会话 | `RootView.swift` `onReceive(openSession)` | 直接赋 `model.selectedSessionId` |
| 选中会话 didSet | `AppModel.swift:314` | `pendingState.clear()` / `updateRunningPoll()` / `refreshInteractions()` 全部有 guard |
| 冷启动连接 | `AppModel.swift` `start/connect/open/refreshSessions` | 全程 timeout + try?，无强制解包 |
| Shell 挂载 | `MizarShell.swift` / `ShellState.swift` | 无数组下标、无强制解包 |
| 会话详情 | `SessionDetailView.swift` | 对未知会话有完整兜底（**已实证**） |
| 会话渲染 | `ConversationView.swift` | 无 `try!`/`as!`/下标崩溃 |
| 协议层 | `MizarKit`（Connection/Settings/LiveActivity/Backoff） | actor + 防御式 continuation 管理 |
| 推送载荷 | `dsh-relay/src/apns.ts` `buildPayload` | 载荷极简，无危险字段 |

实证方式：在模拟器安装当前 HEAD 的预构建，连 mock host，用
`-mizarSelectSession nonexistent-session-xyz` 启动 —— 应用正常渲染、不崩溃。

## 3. 已修复的缺陷

### 缺陷 1 — 冷启动通知竞态（已修复）

**机制**：app 未运行时点击通知，UIKit 在 SwiftUI **RootView 挂载之前**就投递
`userNotificationCenter(_:didReceive:)`（scene 连接是异步的）。此时
`NotificationCenter.default.post(openSession)` **没有任何订阅者，通知被静默丢弃** ——
app 打开后停在会话列表，而不是推送指向的会话。这正是 `PushController.swift`
文件注释里描述的失败模式，原方案没有覆盖这个竞态。

**修复**（`PushController.swift` + `RootView.swift`）：
- 新增 `@MainActor enum PendingPushSession`：`stash(_:)` / `take()` 的一格暂存。
- `didFinishLaunchingWithOptions` 里读 `options[.remoteNotification]` 取 sessionId
  并暂存（`MainActor.assumeIsolated`，UIApplicationDelegate 保证主线程）。
- `didReceive` 除了 post 之外也暂存同一事实。
- `RootView.onAppear` 消费暂存（覆盖「post 早于挂载」的时序）；
  `RootView.onReceive` 在收到 post 时清空暂存（防止同一请求被开两次）。

两种到达顺序都恰好打开一次，且不会把一次点击留到下次启动。

### 缺陷 2 — ForEach 重复 ID 硬崩（已修复，唯一能闪退的候选）

**机制**（`MizarKit/Sources/MizarKit/Conversation.swift`）：
- `SessionRecord.recordId`：记录没有 `seq` 时退化为 `"unknown-\(eventName)"`。
- `conversationTurns()`：同页记录追加进 turn 的 `prompts`/`steps` 时不去重
  （只有跨页合并的 `mergeTurns` 去重）。

同一页里**两条同类型且都无 `seq` 的记录**（插件注释明确说过一个 prompt 会以
RPC source + inbox splice 两个 `user/message` 事件到达）→ 两个同 id 的
`ConversationItem` → `ForEach(id: \.element.id)` **重复 ID 硬崩**。

**实证**：修复前同一页两条无 `seq` 的 `user/message` 产出
`["unknown-user/message", "unknown-user/message"]`；修复后为单条。

**修复**：`conversationTurns()` 增加 `place(_:for:as:)`，按
**「轮次 + 提示/步骤」**作用域去重（与屏幕上各个 `ForEach` 的键一一对应，
既消掉同轮重复，又绝不误伤另一轮同名的提示）；`conversationItems()`
同样加 id 去重。带 `seq` 的记录完全不受影响（id 是 `seq-<n>`，天然唯一）。

回归测试：`MizarKitTests/ConversationTests.swift` 新增两条 ——
「不编号的记录不能产生两个同 id 行」与「去重只在一轮之内，不跨轮」。

### 缺陷 3 — `JSONValue.intValue` 的转换陷阱（已修复）

`Int(rounded)` 对超出 `Int` 范围的有限 Double（如 `1e300`）会 `Fatal error`。
改为 `Int(exactly:)`：越界读作 nil，由各处既有的 `?? nil` 兜底，一个坏字段
不再能带走整个进程。

## 4. 验证方式（本会话无法用 xcodebuild / swift test 的原因与替代）

- **无法构建 app target**：本会话沙箱使 `swift-plugin-server` 恒报
  malformed response（任何 `@Observable`/`@State` 宏编译失败）。
- **无法 `swift test`**：SwiftPM 清单编译被沙箱的 `sandbox_apply` 拒绝。
- **替代验证**（均已执行并通过）：
  1. `swiftc -typecheck -swift-version 6` 全 MizarKit 模块 —— 零错误；
  2. 用 MizarKit 编译出的模块 + 桩类型，对 `PushController.swift` 做
     iOS SDK 下的完整类型检查 —— 零错误；
  3. 直接 `swiftc` 链接一个独立验证程序（20 项断言，覆盖无 `seq` 重复、
     带 `seq` 回归、跨轮不误伤、`intValue` 越界）—— 全部 PASS；
  4. `ConversationTests.swift`（含新增两条测试）对 `-enable-testing` 模块
     类型检查 —— 零错误；
  5. `RootView.swift` 仅语法检查（`@State` 宏插件不在可加载路径中），
     新增代码全部是对已类型检查过的 `PendingPushSession` 的调用。
- **无法点击真机通知**：macOS TCC 拒绝 GUI 自动化，`simctl privacy grant`
  也被拒，模拟器内无法授予通知权限，`simctl push` 无法投递。

## 5. 若修复后仍复现，需要的下一步

1. 取崩溃日志：真机分析数据 / App Store Connect 崩溃 / Xcode 设备窗口。
2. 看栈帧：SwiftUI + "duplicate" → 缺陷 2 方向上还有别的重复源；
   `JSONValue` `Int.init` → 已修；都不是 → 按日志继续。
3. 补一条真机 UI 测试：`simctl push` + 通知中心点击（XCUITest 可驱动
   SpringBoard），锁住这条路径。

## 附：本机复现环境备忘

- mock host 需在**非沙箱**模式启动，否则模拟器访问不到：
  `cd iOS && node scripts/mock-host.mjs 19440`
- 模拟器里 app 的 Keychain 凭据**卸载后仍在**（19440 是旧配对端口）；
  要重新配对用 `-mizarPairURI mizar://pair?h=127.0.0.1%3A19440&c=MOCK-CODE&n=Mock%20Mac&v=1`。
- 当前 HEAD 的模拟器构建在
  `.devcache/DerivedData/Build/Products/Debug-iphonesimulator/DSH-Mizar.app`。
