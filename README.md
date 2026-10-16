# DSH-Mizar 手机端

用手机看 DSH Agent 干活，也能给它发消息、回答审批。iPhone 和 iPad 都能装。

这个仓库是 **iOS / iPadOS App**。另外两个仓库：

| | |
|---|---|
| **DSH-Mizar** | Mac 侧插件（先装它，App 才有东西可连） |
| **DSH-Mizar-Relay** | 中继服务器，让手机从任何网络连上你的 Mac |

## 一、编译运行

需要 Xcode 16 以上（iOS 18 起）。

```sh
git clone git@github.com:ShirazuNagisa/DSH-Mizar-iOS.git
cd DSH-Mizar-iOS

scripts/ios.sh run            # 编译并装进模拟器
```

**装到真机**：用 Xcode 打开 `DSH-Mizar.xcodeproj`，在 Signing & Capabilities 里选自己的
开发者账号，然后选你的设备运行。想用推送的话，App ID 要打开 **Push Notifications**
能力（见 `docs/testflight.md`）。

## 二、配对

1. Mac 上装好插件并重启 DSH，点侧边栏的 **DSH-Mizar**
2. 面板里会出现二维码
3. 手机打开 App，扫码

**没有别的步骤。** 不用填 token，不用填地址，不用改文件。第一次打开会依次问通知权限和
本地网络权限（两个系统弹窗，不会同时出现）；**相机权限只在点「扫码」的那一刻才问** ——
一个大部分会话都用不上的权限，在启动时问就是在教人闭着眼睛点「不允许」。

## 三、手机上能做什么

- 看会话列表和对话正文
- 发消息，打断正在跑的 turn
- 回答审批和提问
- 看用量、缓存命中、上下文占用
- 切换模型、思考强度、权限
- **历史存在手机上**：断网也能翻会话、标题、模型和上下文用量

### 每一轮只显示总结

主机只发总结：每轮结尾是「**已完成，用时 xx 分 xx 秒**」，正在跑的那一轮是
「**深度求索中，用时 xx 分 xx 秒**」。两行都**不能展开** —— 逐步叙述、工具调用这些
过程文本根本不会传到手机上（省带宽，服务器那头的流量主要就是这块）。

### 读不到的东西不会被抹掉

标题、模型、上下文用量来自主机各自的 projection，「这次答得比上次少」是正常回答而不是
失败；读失败也不会把屏幕上已经画出来的东西清掉 —— 那正是「刚点进去，标题和用量全部
消失」的原因。整页读失败时保留上次的内容，并在会话右上角给一个刷新按钮。

## 四、开发

```sh
scripts/swift.sh test         # MizarKit（协议层）全部测试，跑在 Mac 上，1 秒
scripts/ios.sh build          # 编译 App
```

UI 测试要一个假主机（不需要真的 DSH）：

```sh
node scripts/mock-host.mjs 19395 &
scripts/ios.sh test           # 全部 UI 测试（约 6 分钟）
scripts/ios.sh test "iPhone 18 Pro" -only-testing:DSH-MizarUITests/AppFlowTests/<名字>
```

**不要同时起两个 `xcodebuild test`**，会互相抢模拟器，结果是两边都不可信。

## 五、打包

```sh
scripts/release.sh export     # → ../../release/iOS/DSH-Mizar-<版本>.ipa
scripts/release.sh upload     # 直接传到 App Store Connect（TestFlight）
```

签名需要一个付费的 Apple 开发者账号（`MIZAR_TEAM_ID` 可覆盖 team id）。
上传的细节和第一次上传要准备的东西见 `docs/testflight.md`。

## 目录

| | |
|---|---|
| `DSH-Mizar/` | App 本体：视图、AppModel、权限、推送 |
| `MizarKit/` | 协议层（连接、帧、会话模型、缓存），`swift test` 跑的就是它 |
| `DSH-MizarUITests/` | XCUITest，对着 `scripts/mock-host.mjs` 跑 |
| `protocol/fixtures/` | 从真主机录下来的帧（golden frames），两个语言共用 |
| `scripts/` | 编译、测试、假主机、打包 |
| `archive/` | 0.7.2 之前「全量传输」的渲染实现，不编译，留着备用 |

协议本身在插件仓库：`docs/protocol-v1.md`。
