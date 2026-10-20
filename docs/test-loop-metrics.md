# 指标清单与前后对比（2026-10-20 晚）

> 数据来源：`docs/test-pipeline-handover.md`（基线，2026-10-20 19:12–19:43 实测）＋ 本轮新增实测（下文标注）。
> 方法与口径：墙钟 = 命令从启动到退出；执行耗时 = 测试执行本身；均摊 = 执行耗时/条数。

## 1. 基线（交接文档实测，改造前）

| 场景 | 数量 | 执行耗时 | 墙钟 |
|---|---|---|---|
| 全量 UI（干净） | 80（77 pass / 3 skip） | 1806.6 s | 1831 s |
| 单条 UI 隔离 | 1 | 18.9 s | ~40–60 s（含 build/launch） |
| 单测（MizarKit，host） | 504 tests / 63 suites | 0.185–0.477 s | ~2–6 s |
| 增量编译（1 叶子文件 → build-for-testing） | — | — | 2 s |
| 快照套件（6 tests / 10 refs） | 6 | 0.23–0.43 s | 22–47 s |
| 选中 UI（A 场景，AccountUITests） | 9/80 | 306 s | 340 s |
| 全量 UI（A 场景破坏态） | 80 | 1923.5 s | 1939 s |

## 2. 本轮新增实测（P0 + 阶段 2/3 落地）

| 项 | 结果 |
|---|---|
| P0 impact map 生成 | 耗时 69 min（80/80 条，含重试）；`uiTestCount`=80；PASS 行 29 条贡献 27 个 View 文件映射；dry-run 抽查：SettingsView→9 条、TurnIndex→29 条、RedeemInviteView→1 条；提交 `d1664e6`（含生成器守卫：非 PASS 行不贡献覆盖，防部分覆盖漏测） |
| P0 已知局限 | 51/80 行非 PASS（AppFlow 类内顺序依赖 + 长会话退化，隔离跑无法完全复现套件状态）；这些文件回退全量（零漏测方向）。后续项：按类录制覆盖率（v2） |
| 快照基准定夺 | 在规范设备 `Mizar Runs` 重录 `ComposerControls-labelled`：重录前实测 3877/41600 像素差 = 9.32%（最大通道差 255）→ 重录后 0；复跑 7/7 全绿（含并行会话新增的未跟踪契约测试后）；实质变更仅 1 张 PNG；提交 `b929e65`（分支 feature/local-kernel） |
| 首批 XCUITest 下推 | triage top5 全部处理：#4、#1 全量下推（原用例 XCTSkip 占位）；#2/#3/#5 部分下推（原用例保留：placeholder 为 UIKit-backed 不跟随渲染 locale / gate 规则在 AppModel / mock 计数半截待下沉）；快照套件 **15 tests / 23 refs 复跑全绿（执行 2.8 s）**；提交 `ff82c1a` `d4585ab` `54a352b` `296599e` |
| AppFlowTests 拆类 | 57 条 → 基类 + 4 类（Launch 10 / SessionDetail 14 / TurnLifecycle 15 / Navigation 18），方法体字节级一致、总用例数不变（80）；map 同 commit 重命名无残留；dry-run 已识别新类名；提交 `97b08c2` |
| mock 端口按类隔离 | 11/12 类主端口全隔离（Account 因写入守卫暂留 19395，但为唯一用户＝实际仍隔离）；第二台机因同一守卫暂留共享 19396（限并行时两个 AppFlow 子类同跑才有污染面）；提交 `9ec559c` + 补完 `186fde6`；受限的 1 行 env 改法见报告由用户定夺 |
| @testable 收敛 | 未落地：替换 42 文件后编译器暴露 internal memberwise init 依赖（RunningPollTests/SessionRow 等），验证又两度被并行 WIP 的编译破坏打断，工作区改动被并行会话清除；结论：需要先下沉 public init 设计（超出本轮机械替换范畴），遗留为后续项 |
| 串行全量（改造后，80 条） | 执行 **1756.2 s** / 墙钟 ~29.5 min；**74 pass / 1 fail（＝既有 LANFailover 环境失败，非本次改动）/ 5 skip**（2 迁移占位 + 3 截图 tour）；拆类后新类名全部被发现并执行 |
| 并行全量（worker=2，80 条） | 执行 ___ / 墙钟 ___；pass/fail/skip = ___ |
| 并行全量（worker=2） | **未测得**：两次尝试均 wedge——45 字节日志、0 clone、0 测试输出（7–18 min）、xcodebuild ~14% CPU 空转，复现判定为环境级阻塞（Xcode 27 clone 行为，交接文档已列未验证项）；开关本身已生效（echo 确认 + 参数透传验证） |
| 串行 vs 并行一致性 | 并行数据未能取得；串行侧 74P / 1F（＝既有 LANFailover 环境失败）/ 5S，失败集合与基线一致，拆类/隔离/迁移零回归 |

## 3. 网络请求次数前后对比

| 层 | 改造前 | 改造后 |
|---|---|---|
| 单测层（MizarKit） | `URLSession.shared` 0 处；HTTP/WebSocket 走注入 transport | 不变；回放层 `networkAttempts` 恒 0（HTTPReplay.swift:102，测试断言 attempts=1, hits=1, networkAttempts=0） |
| UI 测试层 | 全部连 127.0.0.1:19395/19396 loopback mock，0 真实外网 | 不变（mock 端口按类隔离，仍全 loopback） |
| 真实外网字面量 | 仅 `AccountClient.productionBaseURL`（生产常量，测试经注入覆盖） | 不变（audit-stage2 §8 全量扫描证据） |
| 断网稳定通过 | — | 回放 miss 即抛 `HTTPReplayError.noFixture`（无网络回退路径）；黑名单主机离线证明测试 + 全套单测通过 |

## 4. token 效率基线（代理方法）

- 代理口径：一次改动反馈给 AI 的日志字节数 ÷ 4 ≈ token 量级（AI 不吞全部日志时按实际注入计）。
- 实测（A 场景，.devcache/phase2-evidence/）：`full-a.log` = 10103 B ≈ 2.5K token；`select-a.log` = 1170 B ≈ 0.3K token → **选中日志 ≈ 全量的 1/8.6**。
- 快照层反馈：失败信息直接报像素/文件（docs/snapshots.md），单条 KB 级。
- 目标表（阶段 1–3 全部落地后，同一类改动）：

| 改动类型 | 墙钟：前 → 目标 | token（日志代理）：前 → 目标 |
|---|---|---|
| 叶子 View 改动 | 32.3 min（全量）→ ≤6 min（选中） | ~2.5K → ~0.3K（↓ ~8.6×） |
| 布局/文案改动 | 32.3 min → ≤1 min（快照） | ~2.5K → KB 级（↓ ~50×） |
| 状态/流程改动 | 32.3 min → ≤6 min（选中）或全量并行 | ~2.5K → ~0.3K 或并行全量 |
| 发布前全量 | 30.5 min（串行）→ ___（worker=2 并行） | 日志经 xcresulttool 摘要，不含全量输出 |

## 5. 各手段对墙钟的贡献拆解（阶段 3 验证）

| 手段 | 状态 | 贡献 |
|---|---|---|
| 选择性测试（阶段 1，map） | 本轮启用 | 叶子改动反馈 32.3 min → 340 s 实测（1/5.7） |
| 快照下推（阶段 2） | 本轮扩容 | 布局/文案反馈 → 秒级（0.3 s/条 vs 22.6 s/条） |
| build/execute 分离（ios.sh test-fast） | 已具备（审计确认） | 增量构建 2 s，执行不再付全量编译 |
| AppFlowTests 拆类 | 本轮 | 并行化的前提（XCTest 按类分发）；不单独提速 |
| mock 端口按类隔离 | 本轮 | 并行正确性的前提（共享 mock 会互相擦状态） |
| -parallel-testing-enabled（worker=2） | 开关已落地（`391a780`）；实测受阻（clone wedge），贡献未测得；理论 ~1.9×（12 类均分 2 worker）待环境恢复后同命令补测：`PARALLEL_WORKERS=2 scripts/ios.sh test "Mizar Runs" -resultBundlePath .devcache/phase34-parallel.xcresult` |
| 合并前门禁 | `scripts/pre-merge.sh`（`a50741a`）：单测+快照+选择计划一键；`--with-ui` 加跑选中 UI |
| @testable → import（44 处） | 本轮 | 单测增量编译路径减少跨模块可见性检查（编译 2 s 基线下收益以构建日志为准） |

## 6. 回滚

| 改动 | 提交 | 回滚方式与影响 |
|---|---|---|
| impact map | `d1664e6`（main） | `git revert d1664e6`；选择器退回全量（安全，宁慢不漏） |
| 快照基准重录 | `b929e65`（feature/local-kernel） | revert 恢复旧 PNG，跨实例 1px 差重现（仅 ComposerControls-labelled） |
| 首批迁移（快照测试 + XCTSkip 占位） | ___ | revert 后占位消失，原 UI 用例恢复运行 |
| AppFlow 拆类 + map 重命名 | `97b08c2` | revert 恢复单类与旧 map 名（同 commit 落地，一起 revert） |
| mock 隔离（含补完） | `9ec559c` + `186fde6` | 两条一起 revert 回 19395/19396 硬编码；不设 `PARALLEL_WORKERS` 即串行 |
| 并行开关 | `391a780` | revert 后 ios.sh 恒串行 |
| pre-merge 门禁脚本 | `a50741a` | revert 即恢复 |
| 下推 #4 + skip | `ff82c1a` | revert 后原 UI 用例恢复运行、快照与 ref 删除 |
| 下推 #3（部分） | `d4585ab` | revert 后快照删除、原 UI 用例从未 skip |
| 下推 #1/#2/#5（locale goldens + Picker 抽取） | `54a352b` + `296599e` | revert 后语言/主屏 goldens 删除；#2/#5 原用例从未 skip（仅 #1 在 `54a352b` 内 skip，一并恢复） |

> 本轮提交落在 main 的 `d1664e6` 与 feature/local-kernel 分支（你方会话在 00:33–01:10 之间从 main@`d1664e6` 切出该分支）；逐条可独立 revert，合并时随分支回 main；与用户/并行会话 WIP（AppModel、SessionDetailView、SubagentBoard、TurnIndex、PairingView、LocalKernel/、SubagentPageContract.swift）无文件交集。
