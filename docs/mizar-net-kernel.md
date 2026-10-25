# MizarNet P2P 内核（iOS 仓库内落地）（2026-10-25）

MizarNet 是 DSH-Mizar 的**多端通用 P2P 传输内核**在 iOS 仓库的第一块落地。按用户决策，不建独立仓库：
内核直接写在 `MizarKit/Sources/MizarKit/Net/`，与 App 的解耦由 MizarKit 本身的框架边界保证——
App 不引用 `Net/` 下任何类型，只在未来通过 `P2PWebSocketTransport` 经既有的
`makeTransport` 工厂注入（与 `LocalKernelTransport` 同款接线方式）。

总计划在工作区 `docs/p2p-transport-kernel-plan.md`；本文只记录 iOS 仓库内这部分的设计与边界。

## 1. 文件清单

### 内核骨架（第一轮，2026-10-25 白天）

| 文件 | 职责 |
|---|---|
| `Net/MizarNetCodec.swift` | base64url 与 Crockford base32（内部） |
| `Net/MizarNetIdentity.swift` | Ed25519 端点身份；从 hostSecret / 设备令牌确定性派生；签名与验签 |
| `Net/MizarNetTicket.swift` | 拨号票：端点公钥 + 中继提示 + 直连提示；base64url JSON 线格式 |
| `Net/MizarNetCandidate.swift` | 候选地址（host / srflx / relay），ICE 优先级公式 |
| `Net/MizarNetSignaling.swift` | 信令消息（hello / candidates / bye）+ `MizarNetSignalingTransport` 协议 + 基于任意 `WebSocketTransport` 的信令通道 |
| `Net/MizarNetEngine.swift` | **引擎契约**：`MizarNetEngine` / `MizarNetStream` / `MizarNetPathKind` / `MizarNetHealth` / `MizarNetError` |
| `Net/MizarNetPathPolicy.swift` | 全部可调数字（打洞预算、保活间隔、降级阈值、退避、轮次、分片、STUN 预算） |
| `Net/MizarNetConnection.swift` | 连接状态机（actor）：拨号 / 接受 / 信令消费 / 健康监控 / 关闭 |
| `Net/P2PWebSocketTransport.swift` | `WebSocketTransport` 实现 + `mizar-net://dial?t=…` URL 契约 |

### 真引擎（第二轮，2026-10-25 深夜）

| 文件 | 职责 |
|---|---|
| `Net/MizarNetSTUN.swift` | RFC 5389 绑定事务：请求构造、XOR-MAPPED-ADDRESS 解析、未知属性跳过 |
| `Net/MizarNetUDPSocket.swift` | BSD UDP socket 封装（一个端口绑定全程稳定）、`DispatchSourceRead` → `AsyncStream`、主机候选枚举、DNS 解析 |
| `Net/MizarNetCrypto.swift` | X25519 临时密钥 + Ed25519 签名握手、HKDF 双向会话密钥、ChaCha20-Poly1305 逐包封装（nonce = 包号） |
| `Net/MizarNetPunchPacket.swift` | 线格式：15 字节头（magic/type/connId/len）+ ClientHello/ServerHello/Data/Ack/Keepalive/Close 六种报文 |
| `Net/MizarNetSession.swift` | 可靠会话：消息保序、分片重组、ACK/重传（300ms 起翻倍）、保活、空闲判定、健康 |
| `Net/MizarNetQUICEngine.swift` | 引擎本体：socket 生命周期、候选收集（host + STUN）、打洞轮次、接受路径、STUN 响应路由、健康聚合 |

测试：`MizarNetTestSupport.swift`（loopback 引擎/流/信令 + FakeSTUNServer）+
`MizarNetTests/Crypto/STUN/PunchPacket/QUICEngine` 五个测试文件，共 46 个测试。

## 2. 设计要点

**引擎契约是内核的全部边界。** 生产引擎（QUIC / UDP 打洞，后续引入 Rust 核心或
Network.framework 实现）只需满足 `MizarNetEngine`：dial(ticket:timeout:)、
incomingStreams()、localCandidates()、offerCandidates(_:)、networkChanged()、health()。
连接状态机、传输接缝、测试全部与引擎无关——测试里的 loopback 引擎用两个进程内管道
就驱动了真实的状态机。

**协议层零改动。** `P2PWebSocketTransport` 实现 `WebSocketTransport` 四方法，
Mizar v1 的帧经任一路径原样承载；配对、鉴权、重连、事件路由全部复用。
URL  deliberately 不用 `ws`/`wss` scheme，避免调用方拿错传输。

**内核不选兜底路径。** 直连劣化时内核丢弃流并报 `failed(.streamClosed)`，
由 App 的 `ReconnectPlan`（唯一知道中继的一方）决定下一步。两个都会选路的组件
迟早吵架。

**身份即密钥。** 端点密钥由 hostSecret（host）或设备令牌（device）经
`SHA256(secret ‖ purpose ‖ 0x01)` 派生，配对建立的信赖直接继承，不新增用户侧密钥。
票只命名公钥，不是凭证；QUIC/TLS 握手证明持有。

**信令复用 relay（端点待部署）。** `WebSocketSignalingTransport` 接受任意
`WebSocketTransport`，relay 的房间级 signal 端点上线后只是两行接线。
信令失败不致命：票里的直连提示足以尝试打洞，relay 路径根本不需要信令。

**状态机：** `idle → connecting → ready(path) ⇄ failed(reason) → closed`。
拨号预算由 task group 强制（输了的一方必须取消，否则留下没人持有的 socket）；
健康监控里 `unknown` 不计入劣化（没测过的路径不是证据）。

**真引擎（QUIC 形态，非 RFC 9000 全集）。**  deliberately 命名的 `MizarNetQUICEngine`
实现了 QUIC 的**形状**而非全集：连接 ID 多路复用（一个 socket 承载所有会话）、
包号即 nonce、逐包 AEAD、ACK 驱动的可靠传输、keepalive、打洞即握手报文
（ClientHello 本身就是探针，省掉单独的探测阶段）。**没有**版本协商、crypto 帧、
流控窗口（重排缓冲 64 包即全部"拥塞控制"）——流量是人际速度的请求/响应 JSON，
一个 cubic 窗口只会增加故障模式。打洞同步用**轮次重复**而非 DCUtR 的 RTT/2
（不需要共享时钟）；被叫方从"报文来自的地址"回包——这正是打洞的核心动作。
握手是精简版 Noise IK：双方静态 Ed25519 身份（配对已建立的信赖）+
每连接新鲜的 X25519 临时密钥（签名绑定，防中间人；临时密钥，向前保密）。

**IPv4 only。** 运营商在向 IPv6-only + NAT64 迁移，但本项目部署的 relay 今天全程 v4，
v4-only socket 诚实于它能打通的范围；候选类型已会说 v6，加它是一个 socket 模式位，
不是重构。

## 3. 测试与验证

```
cd iOS && scripts/swift.sh test     # 602 tests / 75 suites 全绿（MizarNet 46 个）
```

覆盖：身份派生/签名、票与 URL、候选优先级、信令编解码与经 WebSocket 的信令、
密钥协商与 AEAD（含篡改/错号/错密钥的负例）、STUN 编解码（XOR/普通/错误事务/
垃圾/未知属性）、报文编解码（hello 签名绑定、data 包 AAD、控制包）、
**真 UDP 集成**：回环打洞、双向消息、3000 字节跨分片重组、无监听拨号超时、
并发拨号拒绝、FakeSTUNServer 的 STUN 发现、网络变化后会话存活、
`P2PWebSocketTransport` 经真 UDP 承载 Mizar 帧、仅凭信令候选中介的打洞。

## 4. SDK 陷阱记录（2026-10-25，Xcode 27 / Swift 6.4）

- `CryptoKit.ChaCha20Poly1305` 已更名 `ChaChaPoly`；`MizarNetCrypto.swift` 用
  `#if compiler(>=6.4)` 兼容两种 SDK 代号（算法与线格式相同，互通）。
- CryptoKit 返回的切片（`SealedBox.ciphertext/tag`）`startIndex` 非 0；
  `+` 保留该索引，之后按绝对位置 `subdata` 会**陷阱**。`seal()` 用 append 归一化，
  `open()` 按 `startIndex` 相对切片。
- `Data.subdata(in:)` 的**空范围会陷阱**（`0..<0` 不是空 Data）。所有长度字段
  必须先判 > 0 再切片。
- `SealedBox.combined` 含 12 字节 nonce 前缀；线上只带 ciphertext+tag，
  nonce 由包号推导。

## 5. 未做（下一步）

1. **跨 NAT 实测**：回环证明了打洞的每个零件，没证明 NAT。真机/真网矩阵
   （家用锥形、运营商对称/CGNAT、UDP 封锁）是计划 §8 的事。
2. **relay signal 端点**：`dsh-relay` 新增 `/r/<room>/signal` 路由与隧道 `signal` 帧
   （工作区计划 §5.5），上线后 iOS 侧接线 `WebSocketSignalingTransport`。
3. **App 接线**：`ReconnectPlan` 增加 p2p 路由、配对 URI / `host.info` 增加端点公钥
   可选字段（纯加法）、设置项开关。
4. **桌面侧**：`dsh` 插件 `src/transport/p2p/`（与 `RelayClient` 同构，回放 loopback）。
5. **丢包/乱序注入测试**：loopback 不丢包，重传与重排路径只有代码审读级覆盖。
