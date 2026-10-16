# 全量消息传输（已归档）

这里放的是 **0.7.2 之前** App 侧的「全量传输」渲染：可以展开的 turn 行、展开里的
步骤/工具行，以及 `assistant/attempt` 的解析。**不参与编译**
（Xcode 只编译 `DSH-Mizar/`、`MizarKit/Sources/MizarKit/`、`DSH-MizarUITests/`
三个目录，`archive/` 不在其中），也**没有删掉**，留着以后要用。

## 为什么拿掉

0.7.2 起主机只发总结：每轮只传你的提问、`turn/start`、`turn/end`、每个 `step/start`
和模型最后那条有正文的消息。逐步叙述、工具调用与结果、未结束那一轮的中间回复都不传了
—— 全量历史经中继是服务器上最大的一块流量。

所以 turn 行不再能展开（展开本来就是给过程文本用的），「已完成，用时 xx」和
「深度求索中，用时 xx」两行下面直接就是这一轮的总结。

## 文件

| 文件 | 是什么 |
|---|---|
| `app/ConversationView.swift` | 归档时的视图：带 `DisclosureGroup` 的 `TurnSection`、步骤行的展开与收起 |
| `app/Conversation.swift` | 归档时的记录解析：`assistant/attempt`、工具/活动行、按步骤分组的 turn |

主机侧的对应实现归档在 **DSH-Mizar** 仓库的 `archive/full-message-transport/`。

## 要用回来的话

1. 把两个文件拷回原路径（`DSH-Mizar/Views/ConversationView.swift`、
   `MizarKit/Sources/MizarKit/Conversation.swift`），把 `TurnSection` 的展开恢复。
2. 主机侧也要一起改回整页转发 —— 只改 App 会得到一个空的过程列表。
3. 注意 **UI 测试会跟着变**：`expandTurns` 之类的辅助函数当时就是为展开写的，现在
   已经删掉了。
