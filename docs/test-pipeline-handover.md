# 测试流水线交接文档（2026-10-20）

本文档记录本轮测试基础设施改造的**已完成部分、实测数据、环境副作用、回滚方式与剩余工作**。
按时间分两阶段：阶段 1「按 diff 选测 + 基线测量」，阶段 2「HTTP 回放 + 快照测试 + live 分层」。
所有提交都在 `main`；`git revert <sha>` 即可单独回滚，未涉及数据迁移或业务语义。

---

## 0. 速查

```sh
cd iOS

# 日常：按 diff 选测（默认 replay 层，绝不走真实网络/模型）
scripts/test-select.sh                 # diff vs origin/main + 工作区
scripts/test-select.sh --dry-run       # 只打印选择计划与原因
scripts/test-select.sh --full          # 忽略选择，单测全量 + UI 全量
scripts/test-select.sh --live          # 显式 live 层（真实 host，本地默认不用）
scripts/test-select.sh --files a,b     # 用指定文件列表验证选择逻辑

scripts/swift.sh test                  # MizarKit 单元测试（宿主机，秒级）
# 快照测试（新 target，不启动完整 App）
xcodebuild test -project DSH-Mizar.xcodeproj -scheme DSH-Mizar-Snapshots \
  -destination "platform=iOS Simulator,name=Mizar Runs" \
  -derivedDataPath .devcache/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -collect-test-diagnostics never

# 全量 UI（发布前才跑；约 30 分钟）
scripts/ios.sh test "Mizar Runs" -resultBundlePath .devcache/full.xcresult

# 重新生成 impact map（当前缺失，见 §6；约 40–50 分钟，需独占模拟器）
scripts/record-impact-map.sh "Mizar Runs"
```

> 模拟器：本轮新建了干净的 `Mizar Runs`（iPhone 18 Pro / iOS 27.0），当前处于 shutdown。
> 原有 `iPhone 18 Pro` 的 testmanagerd 曾卡死，已重启并恢复中文语言；`Mizar Runs` 是当前
> 唯一稳定可跑测试的设备。不需要时可 `xcrun simctl delete "Mizar Runs"`。

---

## 1. 基线与瓶颈（实测，2026-10-20 19:12–19:43）

| 指标 | 实测值 |
|---|---|
| 全量 UI 套件 | 80 条 XCTest（77 pass + 3 skip），测试执行 **1806.6 s**，墙钟 **1831 s（30.5 min）**，均摊 22.6 s/条 |
| 单条 UI 最快证据 | 单条隔离跑 18.9 s（含 App 启动） |
| 单测（MizarKit） | 477 tests / 59 suites，执行 0.185 s，墙钟 6.0 s |
| 增量编译（改 1 个叶子文件 → build-for-testing） | **2 s** |
| 历史 DerivedData | 10 个并存，共 ~3.1 GB（此前反复整构建的痕迹） |

按类耗时：AppFlowTests 57 条 / 1196.4 s，AccountUITests 9 / 281.5 s，Feature094UITests 5 / 130.3 s，
LanPriorityUITests 1 / 86.2 s，ActivityUITests 2 / 36.0 s，RunningDetailUITests 1 / 33.0 s，
ForkedSessionUITests 1 / 25.7 s，LANFailoverUITests 1 / 17.5 s，ScreenshotTour 3 / 0.2 s（环境变量未设时跳过）。
最慢两条：`testLocalNetworkFirstGatesTheScanAndSurvivesARelaunch` 86.2 s、
`testTheSettingsScreenFollowsTheLanguage` 62.3 s。

**结论：编译不是瓶颈（2 s）；瓶颈是「每次改动触发哪 80 条测试」与「失败时的日志/token 成本」。**
单元测试层已经足够快，不应再往里面做选择。

其他侦察结论：
- `URLSession.shared` 在 App/MizarKit 中 **0 处**；HTTP/WebSocket 已通过 `HTTPTransport`/`WebSocketTransport`
  协议注入（`MizarKit/Sources/MizarKit/PairingClient.swift:21-40`），无需新增 session 抽象。
- 所有 UI 测试都连本机 mock host（127.0.0.1:19395/19396），**当前不存在真实外网/live LLM 测试**。
- UI 测试 9 个类、单 target；无 `.xctestplan`、无 CI。

---

## 2. 阶段 1：按 diff 选测（已落地，未完全生效）

### 2.1 文件与机制

| 文件 | 作用 |
|---|---|
| `scripts/test-select.sh` | 入口：算 diff → 选择计划 → 跑单测 + 选中的 UI 子集；打印模式/原因/未跑的类；`--dry-run/--full/--live/--files` |
| `scripts/test-selection.py` | 选择逻辑与配置校验（glob、强制全量、路由、impact map 完整性） |
| `test/test-routing.json` | 策略：强制全量路径、unit-only 路径、无需测试路径、显式路由、`expectedUiTests` |
| `scripts/record-impact-map.sh` | 生成 `test/impact-map.json`：逐测试跑覆盖率，得到「测试 → 覆盖的 View 源文件」 |
| `scripts/impact-map.py` | 逐测试覆盖率解析/合并（xccov JSON → per-test 文件列表 → impact map） |
| `AGENTS.md` | AI/人 的工作规则：默认命令、强制全量条件、分层、回滚约定 |

选择规则（保守，零漏测优先）：
1. 单测永远全量（`scripts/swift.sh test`，几秒）——不在快层做选择。
2. UI 只在有证据时收窄：`test/impact-map.json` 中该文件对应的测试，或 `test-routing.json` 的显式 route。
3. 强制全量：`DSH-Mizar.xcodeproj/**`、`*.xcscheme`、`*.xctestplan`、`MizarKit/Sources/**`、
   `MizarKit/Package.swift`、`protocol/**`、`scripts/**`、`test/**`、`package.json`、
   `DSH-Mizar/App/**`、`DSH-Mizar/Design/**`、本地化/资源/plist/entitlement、LiveActivity target、未知文件。
4. 不完整/过期的 map 一律当没有（`uiTestCount` 与当前 UI 测试数不符即回退全量），宁可慢不可漏。
5. 输出显式列出「未跑的类」，不允许静默跳过；失败解析用 `xcresulttool`（Xcode 27 的 bundle 已无 sqlite）。

### 2.2 A 场景验证（叶子改动 vs 全量，已完成）

构造：在 `DSH-Mizar/Views/Account/RedeemInviteView.swift` 里故意把 redeem 成功文案改成不含
"accepted/Paid until" 的字符串；`test/test-routing.json` 加一条已验证路由：
`RedeemInviteView.swift → AccountUITests`。

| 运行 | 用例 | 失败 | 墙钟 |
|---|---|---|---|
| 选中（`scripts/test-select.sh --files …`） | **9/80**（AccountUITests） | 2 = 回归 1 + 隔离跑偶发 1（About 测试，全量中通过） | **340 s**（单测 8 s + UI 332 s，UI 执行 306 s） |
| 同状态全量（`scripts/ios.sh test …`） | 80（75 pass / 3 skip） | 2 = 本回归 `testRedeemInviteMakesAccountPaid` + 既有环境失败 `LANFailover…FailsOverToTheRelay`（干净状态同样失败） | **1939 s（32.3 min）**，测试执行 1923.5 s |

结论：**由改动造成的失败集合 ⊆ 选中集合**（1 条，选中 9 条中含它），无漏测；子集墙钟为全量的 1/5.7。
B 场景（改 `MizarKit/Sources`）与 C 场景（改 scheme / 路由配置）dry-run 均强制全量（按设计）。

证据留存：`.devcache/phase2-evidence/`（`full-a-summary.json`、`full-a.log`、`select-a.log`；
`.devcache/` 已 gitignore，仅本机留存）。

### 2.3 当前限制

**`test/impact-map.json` 尚不存在**，所以除上面那一条显式路由外，任何 View 改动仍回退全量。
生成器在本机反复遇到模拟器 test runner 卡死（`test runner hung before establishing connection` /
`preflight Busy`）而中止；已加固：连续 3 次启动失败即退出、`runs.tsv` 断点续跑、
不完整 map 被选择器拒绝。换到干净的 `Mizar Runs` 模拟器重跑即可。

---

## 3. 阶段 2：回放 + 快照 + 分层（基础设施已落地）

### 3.1 HTTP 回放（HAR）

- 新文件 `MizarKit/Sources/MizarKit/HTTPReplay.swift`：`HTTPReplayTransport: HTTPTransport`，
  读 HAR 1.2 目录（`MIZAR_HTTP_FIXTURES`），按 method + 绝对 URL（+ 可选 body，JSON 结构化比较）匹配；
  未命中抛 `HTTPReplayError.noFixture`，**类型里没有 URLSession，结构上不可能回退到网络**。
- 夹具：`protocol/fixtures/http/{pair-success,account-me,login-401}.har`，由
  `scripts/record-http-fixtures.sh` 从 `scripts/mock-host.mjs` 确定性录制（连跑两次 sha256 相同）。
- 测试：`MizarKit/Tests/MizarKitTests/HTTPReplayTests.swift` 9 条，含黑名单主机
  `http://10.255.255.1` 只能由夹具应答的离线证明（`attempts=1, hits=1, networkAttempts=0`）。
- 默认行为不变：App 仍用真实 `URLSessionHTTPTransport`；把 replay 接进 App 组合根是后续可选项。
- 选型说明：因为 seam 已经是可注入的 `HTTPTransport`，没有再加 `URLProtocol` 层
  （URLProtocol 只是把同一件事做得更绕，且 miss 时仍需自己保证不联网）。理由与取舍在
  `docs/http-replay.md`。

### 3.2 live 层（保留且可显式触发）

- 契约：`MIZAR_TEST_MODE=replay|live`（默认 replay）；`scripts/test-select.sh --live` 同时设置
  `MIZAR_TEST_MODE` 与 `TEST_RUNNER_MIZAR_TEST_MODE`。
- 单测侧：`MizarKit/Tests/MizarKitTests/LiveNetworkTests.swift` 用 Swift Testing `.enabled(if:)`，
  默认 skip 并打印原因；显式给 `MIZAR_TEST_MODE=live MIZAR_LIVE_BASE_URL=…` 时实测 0.020 s 通过。
- UI 侧：`DSH-MizarUITests/TestLayer.swift`（`mode`/`isLive`/`requireLive`/`requireValue`），
  live 测试必须 `try TestLayer.requireLive(...)`，没有 live 环境时 skip 而不是误连真实 host。
- 注意：现有 80 条 XCUITest 全部走 loopback mock host，**没有一条需要真实网络**；live 层是给未来
  `LiveHostUITests`（如真实配对/真实 host 冒烟）预留的机制，尚未新增该类。

### 3.3 快照测试 target（已可跑，存在 1 条跨设备基准问题）

- 新 target `DSH-MizarTests`（unit-test bundle，`TEST_HOST` 指向 App，Xcode 27 同步目录组风格）+
  独立 scheme `DSH-Mizar-Snapshots`（不污染 `DSH-Mizar` scheme）。
- 机制：`ImageRenderer` 以固定尺寸/2x/英语 locale/固定 Dynamic Type 渲染 SwiftUI 叶子视图，
  与 `DSH-MizarTests/Snapshots/__Snapshots__/` 的 PNG 按容差比较；**只有 `MIZAR_SNAPSHOT_RECORD=1`
  才会写基准，失败绝不自动重录**；另有 `AppSourceContract` 从源码断言 accessibility identifier 仍然存在
  （ImageRenderer 不携带无障碍树）。
- 现状：6 tests / 10 refs；执行 **0.23–0.43 s**（对比 80 条 XCUITest 的 1806.6 s），单条 ~0.1–0.4 s；
  命令墙钟：首次构建 55 s、增量 47 s、`test-without-building` 26 s（主要是模拟器安装/启动）。
- 未采用 swift-snapshot-testing / Prefire：仓库零外部依赖，`scripts/ios.sh` 注释记录了包解析在受限
  文件策略下会失败；Prefire 是 preview 驱动，给不了确定尺寸/像素基准。取舍见 `docs/snapshots.md`。
- **已知问题**：在干净模拟器 `Mizar Runs` 上 5/6 通过；`ComposerControls-labelled` 报
  3877/41600（9.3%）像素差、最大通道差 255，肉眼看是 ~1 px 文本栅格差异——不同模拟器实例间的
  文字渲染差异，不是布局错误。未重录、未放宽阈值；需要决定「在规范设备重录」还是「让 harness 渲染更确定」。

### 3.4 XCUITest triage（只出方案，未迁移）

`docs/phase2-triage.md` 对 80 条逐条给了 file:line、分类与目标层：
layout/copy **31**、state/flow **46**、live-network **0**、截图 tour **3**；
裁剪到 **16 条（20%）** 的保留清单与迁移顺序已给出（AppFlow 10、Account 1、Feature094 2、
LanPriority 1、LANFailover 1、RunningDetail 1）。注意保留的都是重流程，**方法数降到 20% 时墙钟约 30%**。
迁移本身尚未开始（需逐条「等价断言 + 全量对照」，见 §7）。

---

## 4. 本轮提交（回滚用）

| SHA | 内容 |
|---|---|
| `ae26bd9` | 阶段 1：选测机制（`test-select.sh`、`test-selection.py`、`impact-map.py`、`record-impact-map.sh`、`test-routing.json`、AGENTS.md） |
| `ba9c3dc` | 阶段 2：快照 unit-test target + harness + 6 条试点 + 基准 PNG + `docs/snapshots.md` |
| `7189c53` | 阶段 2：HTTP HAR 回放 + 夹具 + 录制脚本 + `docs/http-replay.md` |
| `5885681` | 阶段 2：XCUITest triage 文档 `docs/phase2-triage.md` |
| `6675deb` | 阶段 2：live 分层（`TestLayer.swift` + `test-select.sh --live`） |
| `a5a71b3` | 生成器：runner 连续 3 次启动失败即中止 |
| `e7de20b` | 生成器断点续跑；选择器拒绝不完整 map |
| `7907e75` | 选择器用 `xcresulttool` 解析 Xcode 27 结果包（旧 sqlite 路径已失效） |
| `1d934ce` | A 场景验证后的显式路由：`RedeemInviteView.swift → AccountUITests` |
| 本轮最后一个提交 | 本文档 + `AGENTS.md` 指针（交接入口；`git log -- docs/test-pipeline-handover.md` 可查） |

回滚（新→旧，单条可回）：`git revert 1d934ce 7907e75 e7de20b a5a71b3 6675deb 5885681 7189c53 ba9c3dc`
（阶段 1 的 `ae26bd9` 同理单独 revert。）以上提交与用户自己的提交（如 `f5826b5` 配对路由、
`3486480`/`13aa050`/`305a6af` 抽屉/iPad 相关）文件不重叠，可各自独立回滚。

**注意一次并行冲突**：`305a6af` 是用户侧工具把我的 A 场景故意改名（`turnIndex.row.` → `turnIndex.entry.`）
当作「代码是源、测试去对齐」提交并 push 的；当前 View 与 4 条 UI 测试已一致，语义等价，未回滚。
如需恢复 `turnIndex.row.` 需单独提交。

---

## 5. 环境副作用与本地态

- 新建模拟器 `Mizar Runs`（iPhone 18 Pro / iOS 27.0，当前 shutdown）——本机唯二稳定可跑测试的设备，
  测试命令默认用它；不需要时删除即可。
- 原有 `iPhone 18 Pro`：曾因反复 kill xcodebuild 导致 testmanagerd 卡死，已重启恢复，语言已从临时
  英文恢复为 `zh-Hans-CN/ja-CN`；iPad 模拟器未动。
- `.devcache/phase2-evidence/`：A 场景的全量/选中日志与 summary（本机留存，不提交）。
- 未触碰用户 WIP：`DSH-Mizar/Views/Conversation/{SessionDetailView,TurnIndex}.swift` 的未提交修改、
  以及用户的其它 worktree（`.worktrees/ios-pairing-fix`）都保持原样。
- 本轮反复出现「另一路 xcodebuild 同时在跑」导致的 test manager 卡死/假失败（README 已有同样警告）；
  以后跑全量/生成 map 前务必确认 `pgrep -f xcodebuild` 为空。

---

## 6. 已知未完成 / 阻塞项（按优先级）

1. **impact map 缺失**（P0）：`test/impact-map.json` 未生成 → 除 `RedeemInviteView.swift` 一条路由外
   的选择都回退全量。生成方法：`scripts/record-impact-map.sh "Mizar Runs"`（40–50 min，独占模拟器），
   完成后检查 `jq '.uiTestCount' test/impact-map.json` == 80，并抽查
   `scripts/test-select.sh --dry-run --files DSH-Mizar/Views/SettingsView.swift` 是否出现 "mapped:"。
2. **快照跨设备确定性**（P1）：`ComposerControls-labelled` 1 px 文本栅格差异，需在规范设备重录或在
   harness 层固定渲染；在解决前快照套件是 5/6，绿不了。
3. **XCUITest 迁移未开始**（P1）：80→16 只是方案；需要按 `docs/phase2-triage.md` 逐条迁移，
   每条保留等价断言并做全量对照，然后更新 `expectedUiTests` 与路由/影响表。
4. **既有环境失败**（P2）：`LANFailoverUITests/testTheLANGoingAwayFailsOverToTheRelay` 在干净 HEAD
   的新模拟器上同样失败；另一条 composer 测试在隔离跑偶发失败、全量通过。需要确认前者是 LAN 环境
   问题还是真回归（它不阻塞本轮交付，但会污染全量结果）。
5. **选择器未接快照/新 target**（P2）：改 `DSH-MizarTests/` 或跑快照套件目前不在 `test-select.sh`
   的自动路径里（会走未知文件→全量）；阶段 3 可把「改快照测试→只跑 `DSH-Mizar-Snapshots`」接进去。
6. **CI**（P3）：仓库仍无 CI；建议只做「全量 UI 门禁 + live 抽样」，本地闭环优先（与 AGENTS.md 一致）。

---

## 7. 建议的下一步（含预计耗时）

1. **生成 impact map**（40–50 min，独占 `Mizar Runs`）：跑完后用 3 个 dry-run 抽查
   （Settings/Home/TurnIndex 等），再把 `test/impact-map.json` 单独提交；顺手把 `expectedUiTests`
   与新增/改动的测试数对齐。
2. **快照基准定夺**（10–20 min）：在 `Mizar Runs` 上显式 `MIZAR_SNAPSHOT_RECORD=1` 重录
   `ComposerControls-labelled` 并 review 像素，或改 harness 让文字渲染确定；重录要单独提交（便于审计）。
3. **首批 5 条 XCUITest → snapshot**（1–2 h）：按 triage 的 top5 迁移；每条要求：
   等价断言（locale/尺寸/identifier）+ 跑全量对照一次（约 30 min/次，可攒 2–3 条一批跑）。
4. **批量迁移到 ≤16 条**（按批，约每批 2 h）：每批更新 `docs/phase2-triage.md` 状态、
   `expectedUiTests` 与路由；全量门禁跑一次做对照。
5. **接选择器/CI**（P2–P3）：把快照 target 纳入 `test-select.sh` 路由；CI 只做全量 + live 抽样。

---

## 附：本轮实测数据速查

| 场景 | 数量 | 执行耗时 | 墙钟 |
|---|---|---|---|
| 全量 UI（基线，干净） | 80（77 pass / 3 skip） | 1806.6 s | 1831 s |
| 全量 UI（A 场景破坏态） | 80（75 pass / 2 fail / 3 skip） | 1923.5 s | 1939 s |
| 选中 UI（A 场景，AccountUITests） | 9/80 | 306 s | 340 s（含单测 8 s） |
| 单条 XCUITest | 1 | 18.9 s | ~40–60 s（含 build/launch） |
| 快照套件 | 6 tests / 10 refs | 0.23–0.43 s（另一实例 1.019 s，1 fail） | 22–47 s（安装/启动占大头） |
| 单测套件（当前 HEAD） | 504 tests / 63 suites | 0.202 s | 2 s（热构建） |
| HTTP 回放测试 | 9 | ~0.01 s/条 | 随单测套件 |
