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

### NAT 矩阵沙箱（第三轮，2026-10-25）

| 位置 | 职责 |
|---|---|
| `MizarKit/Lab/MizarNetNATLab/` | 用户态 NAT 模拟器、观测式 STUN 服务器、信令对、矩阵运行器（见 §4）。**独立 SPM target，不进 App** |
| `MizarKitTests/MizarNetNATMatrixTests.swift` | 40 格矩阵断言（`MIZAR_NAT_MATRIX=1` 门控，默认跳过） |

### 跨语言线格式与桌面引擎（第四轮，2026-10-25）

| 位置 | 职责 |
|---|---|
| `MizarKitTests/MizarNetFixtureEmitter.swift` | 写出 `protocol/fixtures/p2p/wire.json`（`MIZAR_P2P_FIXTURES=1` 门控）；同时断言 `sessionKeys` 与 `sessionKeyBytes` 两种推导给出相同字节 |
| `Net/MizarNetCrypto.swift` | 新增 `sessionKeyBytes(sharedSecret:salt:localIsDialer:)`：字节级 HKDF，供第二份实现复现 |
| `Net/MizarNetPortMapping.swift` | 端口映射：NAT-PMP、UPnP-IGD（SSDP + SOAP，HTTP 可注入）、编排；引擎在 `start()` 后申请、半租约续租、`shutdown()` 删除（见 §4.5） |
| `MizarKit/Probe/main.swift` | `mizar-net-probe` 命令行端点：`accept` / `dial`，**只用 MizarKit 公开 API**，给跨语言测试当对端 |
| 插件仓库 `dsh/src/transport/p2p/` | TypeScript 完整引擎：`encoding` / `wire` / `crypto` / `socket` / `stun` / `session` / `engine` / `policy`，规范见 `dsh/docs/p2p-wire-v1.md` |

一份 fixture、两套解码器：任何一个语言单方面改动线格式，另一个的测试就红。
TypeScript 侧的 47 个线格式测试逐字节复现了 hello、data、keepalive、ack、close，
并验证了身份派生、签名、X25519 协商、HKDF 双向密钥与 AEAD 全部与 Swift 一致。

**真连接已验证**（`dsh/test/p2p-interop.test.ts`，`MIZAR_P2P_INTEROP=1` 门控）：
Node 拨 Swift、Swift 拨 Node 两个方向都在回环上打通并交换了消息（各约 380ms）。
第二个方向顺带证明了 **CryptoKit 接受 Node 签出的 Ed25519 签名**——这是字节
fixture 覆盖不到、而一旦不成立整条直连就永远连不上的那一环。

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
cd iOS && scripts/swift.sh test                              # 609 tests / 76 suites 全绿
MIZAR_NAT_MATRIX=1 scripts/swift.sh test --filter MizarNetNATMatrix   # 36 格 NAT 矩阵，约 21s
```

覆盖：身份派生/签名、票与 URL、候选优先级、信令编解码与经 WebSocket 的信令、
密钥协商与 AEAD（含篡改/错号/错密钥的负例）、STUN 编解码（XOR/普通/错误事务/
垃圾/未知属性）、报文编解码（hello 签名绑定、data 包 AAD、控制包）、
**真 UDP 集成**：回环打洞、双向消息、3000 字节跨分片重组、无监听拨号超时、
并发拨号拒绝、FakeSTUNServer 的 STUN 发现、网络变化后会话存活、
`P2PWebSocketTransport` 经真 UDP 承载 Mizar 帧、仅凭信令候选中介的打洞。

## 4. NAT 矩阵：封闭沙箱里的六种网络

macOS 没有 netns/veth，引擎又依赖 CryptoKit 跑不了 Linux 网络命名空间，所以
"封闭沙箱"的正确形态是**用户态 NAT**：真实 UDP socket 按 NAT 语义转发，真实引擎代码
走完整的"STUN 发现 → 信令换候选 → 打洞 → 会话"路径。全部流量只走回环，
确定性、可进 CI、不依赖任何外部服务器。

### 4.1 组成（`MizarKit/Lab/MizarNetNATLab`，独立 target，不进 App）

| 文件 | 职责 |
|---|---|
| `SimulatedNAT.swift` | 六种 NAT 行为：`publicNetwork` / `fullCone` / `addressRestricted` / `portRestricted` / `symmetric` / `blocked`。**映射**：EIM 用一个转发 socket（端口恒定），对称型按目的地址各开一个；**过滤**：全锥放行任何来源、地址受限按 IP、端口受限按 IP:端口、对称型每个转发器只认自己的对端。可串联（CGNAT = 内层 + 外层） |
| `ObservingSTUNServer.swift` | 会说 RFC 5389 的 STUN 服务器，报告它看到的源地址——NAT 后的引擎由此得到 srflx 候选 |
| `LabSignaling.swift` | 进程内信令对，替代 relay 的 signal 端点，其余行为（hello/candidates/bye）与线上一致 |
| `NATMatrixLab.swift` | 单元格定义、运行器、结果表；串联时外层 NAT 先绑 |

**保真度上的一条硬要求**：真实 NAT 的私网地址在公网不可达。回环没有这个分隔，
若不处理，host 候选（`127.0.0.1:转发端口`）会直接命中转发器，"打洞"变成绕过 NAT。
所以每个 NAT 额外绑一个**永不读取的内部端口**作为引擎眼中的 `localAddress`——
发往 host 候选的包如石沉大海，与真实世界一致。矩阵里的每一次打通都只能靠
STUN 观测到的映射，这也正是它值得跑的原因。

### 4.2 结果（2026-10-25，40 格全绿：36 主矩阵 + 4 CGNAT）

行为按 ISO 顺序：public / fullCone / addressRestricted / portRestricted / symmetric / blocked。

| 拨号方 ↓ 接受方 → | public | fullCone | addrR | portR | symm | blocked |
|---|---|---|---|---|---|---|
| public | ✓ | ✓ | ✓ | ✓ | ✓ | ⊘ |
| fullCone | ✓ | ✓ | ✓ | ✓ | ✓ | ⊘ |
| addressRestricted | ✓ | ✓ | ✓ | ✓ | ✓ | ⊘ |
| portRestricted | ✓ | ✓ | ✓ | ✓ | ✗ | ⊘ |
| symmetric | ✓ | ✓ | ✓ | ✗ | ✗ | ⊘ |
| blocked | ✗ | ✗ | ✗ | ✗ | ✗ | ⊘ |

✓ 打通（锥型互打 67–81ms，经对称接受方 298–330ms）· ✗ 超时（对称接受方 682–711ms；
UDP 封锁的拨号方 1.06–1.11s）· ⊘ 无候选 `P2P_FAILED`（1.43–1.84s，含 1s 候选宽限）

CGNAT 四格正如"外层决定命运"：`portRestricted over portRestricted → fullCone/portRestricted`
打通，`portRestricted over symmetric → fullCone` 打通（对端是锥型，能收到对称型主动发出的包
并回到真实源），`portRestricted over symmetric → portRestricted` 失败。

**与 NAT 文献逐条对上**，且每一条都能用一句话解释：

- 锥型对锥型，任意组合都通——双方都能把包送到对方真实的映射地址；
- 对称型**拨号方**仍能打通锥型接受方：接受方收到包后回到"报文来自的地址"，而不是
  回到 STUN 报的那个地址；
- 对称型**接受方**只能被锥型拨号方打通，端口受限拨号方会把它从另一个端口发来的包
  按端口过滤掉；
- 两端都对称，等于两端都在用一个对方不知道的端口说话，必然失败；
- UDP 被封，连候选都没有——这是"必须立刻走 relay"的信号。

失败都在**预算内**发生（≤700ms 或 1.4s），这是 Q2 决策（中继永远兜底）能成立的前提：
打洞失败必须快，快到用户感觉不到。

### 4.3 矩阵抓到的三个真问题（已修）

矩阵的价值不在于它证明了对的，而在于它证伪了三个我以为是正确的假设：

1. **会话与拨号结果的竞态**（第一次跑时 4 个本该打通的格子成了 `timeout`）。
   接受方的心跳式打洞会在拨号方 `activeDial` 建立之前到达，拨号方据此建好会话，
   而打洞循环看到 `sessions` 非空就收工并写下 `dialTimeout`——一个已经接通的连接
   被记成失败。修法：`dial` 先认领既有会话（并 `reconcile` 去重），打洞循环**绝不**
   在"远端已有会话"时写失败，`scheduleCommit` 提到第一个 `await` 之前注册（提交
   就是对"这个会话正在交给调用方"的承诺，打洞循环读它来闭嘴）。
2. **候选为空时立刻失败**。候选经信令到达，比"决定拨号"晚几毫秒；原实现见到
   空列表就 `punchFailed`，把整次拨号浪费在自己造成的竞态上。新增 `candidateGrace`
   （默认 1s）：等候选，而不是失败。
3. **意图判断过窄**。`commit` 曾以 `intent == .accept` 决定是否把会话交给
   `incomingStreams()`，而直接使用引擎的调用方从不声明意图——流被吞掉，测试挂死。
   改为 `intent != .dial`：未声明意图的引擎是在等拨号。

顺带修掉的还有矩阵并行跑的假失败：行与行之间是十几个真实定时器，并行时互相饿死
20ms 的拨号轮询。矩阵是正确性工具不是性能基准，`@Suite(.serialized)` 是它的正确形态
（它自己的文档早就这么写了）。

### 4.4 它证明了什么，没证明什么

**证明了**：过滤与映射语义下的打洞逻辑、候选交换、轮次同步、握手与密钥协商、
双工会话的调和、失败路径的时限——都在真实 socket 上跑通，40 格无一例外。

**没证明**：真实运营商网络里的三件事——(a) NAT 绑定的**超时回收**（沙箱不模拟过期，
所以 22s 保活只是按研究选的数字，没有被矩阵验证）；(b) **端口预测型**对称 NAT 与
UPnP/NAT-PMP 的存在（沙箱是纯对称模型）；(c) 真实丢包/重排/MTU 黑洞（回环不丢包）。
这三件事只有真机 + 真网能回答，是计划 §8 的真机矩阵。

### 4.5 端口映射：矩阵里那一行判决的唯一解

矩阵的结论里有一条是硬的：**对称型接受方打不通**。它的映射随目的地址变化，任何一方从
STUN 学到的地址对它自己都不成立——再多打轮次也翻不过来。

`MizarNetPortMapping.swift` 走另一条路：不问 NAT，直接请路由器开一个转发口。

- **NAT-PMP**：12 字节请求打到网关 5351，三次重试共 750ms；删除就是 lifetime 0。
- **UPnP-IGD**：SSDP 组播发现 → 读描述文档 → SOAP `AddPortMapping`。HTTP 走一个可注入
  的 `MizarNetHTTPClient`，测试因此不需要在本机起一个 HTTP 服务器。
- 两种协议**都不返回外部 IP**，所以映射只提供端口，地址仍来自 STUN；引擎把
  `(srflx 地址, 映射端口)` 配成一个候选（局部优先级 1，排在普通 srflx 之前）。
  没有 STUN 就没有地址可配，映射会被**主动撤销**——不能留一扇开着的门。
- 租约按半租约续租；续租失败立刻撤下候选并停表。

失败是常态：关掉 UPnP 的路由器、公司网关、封锁组播的访客 Wi-Fi，都返回 nil，
打洞照原样进行。15 个测试覆盖了答应 / 拒绝（含 UPnP 718）/ 不应答 / 无地址可配四种结局。

**一个踩到的坑**：`MizarNetUDPSocket.receive(timeout:)` 最初用任务组包 `AsyncStream`，
超时那一路会取消 `next()`——而取消会把迭代器永久结束，于是第一次没应答之后这个 socket
就再也收不到包，三次重试塌缩成一次。现在改成 socket 内部的收件箱 + 定时过期，
读取本身不被取消。

## 5. SDK 陷阱记录（2026-10-25，Xcode 27 / Swift 6.4）

- `CryptoKit.ChaCha20Poly1305` 已更名 `ChaChaPoly`；`MizarNetCrypto.swift` 用
  `#if compiler(>=6.4)` 兼容两种 SDK 代号（算法与线格式相同，互通）。
- CryptoKit 返回的切片（`SealedBox.ciphertext/tag`）`startIndex` 非 0；
  `+` 保留该索引，之后按绝对位置 `subdata` 会**陷阱**。`seal()` 用 append 归一化，
  `open()` 按 `startIndex` 相对切片。
- `Data.subdata(in:)` 的**空范围会陷阱**（`0..<0` 不是空 Data）。所有长度字段
  必须先判 > 0 再切片。
- `SealedBox.combined` 含 12 字节 nonce 前缀；线上只带 ciphertext+tag，
  nonce 由包号推导。
- **CryptoKit 的 Ed25519 签名是随机的**（同一密钥同一消息，两次签名不同——已实测）。
  跨语言契约因此是"能验证"而不是"字节相等"：任何地方都不得用签名做身份判断、
  去重或重放检测；重放靠包号窗口。写跨语言测试时也不要断言重新签一遍得到同样字节。

## 6. 未做（下一步）

1. **真机 + 真网验证**：沙箱矩阵（§4）证明了 NAT 语义下的打洞逻辑，剩下的三件事
   只有真机能回答——真实 NAT 的映射过期、端口预测型对称 NAT、真实丢包与 MTU 黑洞。
2. **relay signal 端点**：`dsh-relay` 新增 `/r/<room>/signal` 路由与隧道 `signal` 帧
   （工作区计划 §5.5），上线后 iOS 侧接线 `WebSocketSignalingTransport`。
3. **App 接线**：`ReconnectPlan` 增加 p2p 路由、配对 URI / `host.info` 增加端点公钥
   可选字段（纯加法）、设置项开关。
4. **端口映射两端都已完成**（iOS `Net/MizarNetPortMapping.swift`、桌面
   `dsh/src/transport/p2p/portmap.ts`）。剩下的接线工作见 §6.1。
5. **丢包/乱序注入测试**：沙箱的回环不丢包，重传与重排路径仍只有代码审读级覆盖。
   下一步给 `SimulatedNAT` 加一档"丢包/乱序"行为，把它也纳入矩阵。

### 6.1 接线进度

桌面侧已接通（2026-10-25）：

1. ✅ **插件常驻引擎**：`dsh/src/net/p2p.ts` 的 `P2PService`，身份由 tunnel secret 派生
   （`SHA-256(secret ‖ "mizar-net/host/v1" ‖ 0x01)`），插件挂载时启动、卸载时关闭。
2. ✅ **流适配**：`StreamChannel` 把 p2p 流包装成监听器认的 `MizarChannel`；监听器的
   连接处理抽成了 `#serve(channel:remote:forgetSocket:)`，WebSocket 与 p2p 走**同一份**
   鉴权与方法分发——直连只是换了一条传输，不是第二套协议。
3. ✅ **信令端点**：监听器在 `/mizar-net/signal` 上开第二个 `WebSocketServer`，
   `P2PService.attachSignal` 收 phone 的 hello/candidates 并回自己的候选。
   relay 无需改动（房间桥接按任意路径转发，`dsh-relay/test/relay.test.ts` 钉住）。
   `host.info` 增加可选 `netEndpointId`（纯加法，老客户端忽略）。
4. ✅ **App 路由**（2026-10-25 晚，**默认关闭**）：`PairedHost.Endpoint` 多了一种
   `.p2p(relayBaseURL:endpointId:)`；`PairedHost` 多了一个可选的 `netEndpointId`，
   由 `host.info` 学到并持久化。开关在**设置 → 传输**，默认关；关着的时候
   `ReconnectPlan.routes(allowingDirectPath:false)` 把 `.p2p` 从计划里和“上次成功的路由”
   里一并摘掉——所以关掉会在下一次重连生效，而不是下一次配对。详见 §6.3。

### 6.2 STUN：已经自建，两端都指向它

2026-10-25 在主力0（124.223.105.30）上把 STUN 做进了中继本身：`dsh-relay/src/stun.ts`
是 RFC 5389 的一个真子集（Binding Request → Success Response + XOR-MAPPED-ADDRESS），
跑在标准端口 **udp/3478**，安全组已放通，`dshmizar.shirazu-nagisa.com:3478` 即地址。

为什么放在中继上而不是单装 coturn：反射放大需要的那套限速（每源 5/s、全局 200/s、
全局桶先扣）中继里已经有了，复用它比复制一份安全逻辑更安全；而且这是一个已经在跑、
已经被监控的进程，新增一个 socket 比新增一个守护进程便宜。

两端的默认值因此统一：

- iOS `defaultSTUNServers = ["dshmizar.shirazu-nagisa.com:3478"]`——与手机本来就要连的
  中继同一个主机名，不新增信任关系；
- 插件 `net.stunServers` 留空，由 `resolveStunServers` 从 `relay.url` 推出：自建中继的人
  得到空列表，不会把电脑通告给我们的服务器。

**没有公共 STUN 兜底**，是刻意的：这台服务器不可达时端点只保留 host 候选，打洞退化为
局域网内，远程会话照旧走中继——用户感知不到差别，换取不把连接事实交给陌生人。

实测（2026-10-25）：从主力1 打过去，32 字节应答、XOR 解出的端口与本地一致、垃圾包无应答、
突发 3/3；Swift 引擎对接同一台服务器 **53ms** 拿到 `124.228.221.210:61921`——真实 NAT
之后的映射，不是回环。

### 6.3 App 里那条路：一次配对怎么变成一个 `.p2p` 路由

```
host.info → netEndpointId（32 字节公钥，持久化进配对记录）
   ↓
PairedHost.endpoints = [ .direct, .p2p(relay:endpointId:), .relay, (备用 relay) ]
   ↓
ReconnectPlan.routes(…, allowingDirectPath: 设置开关)
   ↓
makeConnection(.p2p) → P2PRoute → MizarConnection 拼出 mizar-net://dial?t=…
   ↓
P2PWebSocketTransport（信令通道在 connect 时才打开）
```

几个刻意的选择：

- **迁移不需要动代码**：`netEndpointId` 是 `String?`，合成的解码器对缺失的可选键用
  `decodeIfPresent`，所以 0.9.6 存下的配对记录原样能读，读出来是 `nil`（没有直连路由）。
  测试里钉了一条“没有这个字段的旧 JSON 仍能解码”。
- **信令通道的生命周期归传输自己**：`P2PWebSocketTransport` 拿到的是 `makeSignaling`
  闭包，在 `connect()` 里才打开、在 `close()` 里关闭。原因是启动时所有路由会**同时**
  起跑，输掉的那一条如果提前开了一条信令 socket 就没有人关它。
- **直连不继承中继的延迟**：`AppFlow` 的启动竞速会给“有局域网地址的配对”让中继晚 1.5s
  出发。`.p2p` 不算——一次注定失败的打洞要花三秒，那三秒里中继本来能连上。
- **`isRelay(.p2p)` 是 false**：它的字节不经过中继，界面因此说“直连”而不是“免费服务器”。
- **中继永远在计划里**：`.p2p` 失败就在同一次重连里落到 `.relay`，不需要用户做什么。

**开关默认关**，是发布决定而不是保守：直连是唯一一条成功率取决于中间网络的路由，
而“某个运营商会给什么样的 NAT”只有真机实测才知道。关着的时候所有人的重连速度和今天
完全一样；打开的人为失败的打洞付出几秒。

**一个前提**：`netEndpointId` 由插件提供，而带这个字段的插件（0.8.11 起）**还没发布**。
所以在插件发版之前，配对记录里不会有这个字段，App 也就不会生成 `.p2p` 路由——
开着开关也只是照旧走中继。这是有意的顺序：先让代码就位，再用发版把它点亮。

## 7. 包体（2026-10-25 实测，A/B 构建）

release 构建下，`Net/` 为 MizarKit 增加机器码 207.5 KiB + 代码常量约 17.5 KiB；
`.o` 文件总增量 783 KiB（含符号表，归档后进 dSYM 不计入下载体积）。
**出货包体增量 ≈ 0.2–0.3 MB**，约占 MizarKit 自身机器码的 20%。

矩阵沙箱（`MizarKit/Lab/`）是独立 SPM target，Xcode 工程的同步组只指向
`Sources/MizarKit`，**不进出货包**。
