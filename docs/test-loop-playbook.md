# 测试回路速查（一页）

> 目标：默认回归不走真实网络；布局/文案验证不启动完整 App；反馈回路本地秒级。
> 原理与实测数据：`docs/test-pipeline-handover.md`；指标与回滚：`docs/test-loop-metrics.md`。

## 1. 日常：只跑受影响的测试

```sh
cd iOS
scripts/test-select.sh              # diff vs origin/main + 工作区；默认 replay 层
scripts/test-select.sh --dry-run    # 先看选择计划与原因，不跑
scripts/test-select.sh --full       # 忽略选择：单测全量 + UI 全量
scripts/test-select.sh --files a,b  # 用指定文件列表验证选择逻辑
scripts/test-select.sh --live       # 显式 live 层（设 MIZAR_TEST_MODE + TEST_RUNNER_ 副本）
```

- 单测永远全量（`scripts/swift.sh test`，宿主机 ~2 s），不在快层里做选择。
- 输出会显式列出「未跑的类」——子集不是全量，汇报时必须说明。

## 2. 快照（布局/文案，秒级，不启动完整 App）

```sh
xcodebuild test -project DSH-Mizar.xcodeproj -scheme DSH-Mizar-Snapshots \
  -destination "platform=iOS Simulator,name=Mizar Runs" \
  -derivedDataPath .devcache/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -collect-test-diagnostics never
```

- 重录基准：只在显式 `MIZAR_SNAPSHOT_RECORD=1` 时写基准，失败绝不自动重录；
  在规范设备 `Mizar Runs` 上录，重录单独提交（便于审计）。

## 3. 回放夹具（HAR）录制与更新

- `scripts/record-http-fixtures.sh`：从 mock host 确定性录制 `protocol/fixtures/http/*.har`
  （连跑两次 sha256 相同）。夹具入库前人工 review。
- 回放未命中 = `HTTPReplayError.noFixture`，无网络回退。缺夹具就补夹具，不许绕过。
- UI 测试连本机 mock host（`node scripts/mock-host.mjs 19395`），无真实外网。

## 4. 哪些改动触发全量（test-select.sh 已强制，别犹豫直接 --full）

Xcode 工程/scheme/test plan、`MizarKit/Sources/**`、`MizarKit/Package.swift`、`protocol/**`、
`scripts/**`、`test/**`、`package.json`、`DSH-Mizar/App/**`、`DSH-Mizar/Design/**`、
本地化/资源/plist/entitlement/storekit、LiveActivity target、未知文件；
以及 UI 测试数与 `expectedUiTests` 不符、map 引用了不存在的测试时。
`DSH-MizarTests/`（快照）改动目前也回退全量，直到选择器接入快照 target。

## 5. 全量 / 并行 / 发布前

```sh
pgrep -f xcodebuild                # 必须为空再跑；并行 xcodebuild 会让 testmanagerd 卡死
scripts/ios.sh test "Mizar Runs" -resultBundlePath .devcache/full.xcresult
PARALLEL_WORKERS=2 scripts/ios.sh test "Mizar Runs" -resultBundlePath .devcache/full.xcresult
```

- 并行是按类分发的；改测试代码后先跑一轮串行确认，再开并行对照。
- live 抽样只在 nightly/发布前：`scripts/test-select.sh --live` + `MIZAR_LIVE_BASE_URL=…`。

## 6. 合并前门禁（无 CI 时期的本地约定）

1. `scripts/swift.sh test` 全绿；2. 快照套件全绿；3. `scripts/test-select.sh`
（命中强制全量条件时自动 `--full`）；4. live 抽样仅 nightly/发布前。
`scripts/pre-merge.sh` 把 1–3 串成一键；CI 化时等价命令不变。

## 7. 给 AI 下指令的最小上下文

- 说清三件事：改了哪些文件 + 意图 + 期望验证层（单测/快照/UI 子集/全量）。
- AI 默认先 `--dry-run` 看选择计划再跑；失败时贴 `xcresulttool` 摘要，不贴全量 log。
- 需要 live 层必须显式说；默认永不真实网络。模拟器一律 `Mizar Runs`。
