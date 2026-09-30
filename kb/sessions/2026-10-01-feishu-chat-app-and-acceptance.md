---
created: 2026-10-01
tags:
  - session
  - feishu
  - swiftui
  - acceptance
  - notifications
---

# FeishuChat MVP：完成 macOS App，并用真实账号逐项验收

## 概要

这份总结覆盖两个 session：2026-09-29 晚上做完第 2 阶段（`FeishuChatCore` 包和 App），2026-09-30 到 10-01 做完第 3 阶段（验收与收尾）。第 0、1 阶段的经过记在[计划](../plans/2026-09-29-feishu-chat-mvp-plan.md)第 11 节和[协议探路笔记](../notes/2026-09-29-protocol-spike.md)里，这里不重复。

第 2 阶段按计划做出了 App：拉起并守护后端子进程、扫码登录页、会话列表、消息页和发送、本地通知和 Dock 角标、开机启动。纯逻辑（接口模型、SSE 解码、通知策略、消息合并、翻页游标、会话排序、时间格式）都放在 Core 包里，有 46 个测试。

第 3 阶段卡在一件事上：测试群 litetest 里只有用户本人，而本人发的消息不计未读、不弹通知。用户给群里加了一个自定义机器人，机器人的消息会计未读也会触发通知，之后第 2、3、4、6、7 项都能自动跑。验收第 1 到 9 项全部通过，第 1 项有两处出入（一处已修，一处登记为已知问题）。验收过程中发现并修掉了四个缺陷。计划第 0 节的完成标准全部满足。

## 验收结果

证据都在 `tmp/2026-09-29-feishu-chat-mvp/`（不入库，里面有真实的会话名和消息预览）。

| 验收项 | 结论 | 怎么验证的 |
|---|---|---|
| 1 会话列表和手机一致 | 通过，有出入 | 用户截了官方客户端的会话列表，和 App 的前 20 个逐条对照。顺序一致；官方多出的三条是文档卡片、会话盒子、应用卡片（有意不显示）。出入见下 |
| 2 新消息 5 秒内通知，点击跳转 | 通过 | 机器人发消息后 1.2 秒 App 收到，1.5 秒内发出通知，横幅有截图。通过辅助功能接口点横幅，App 打开了 litetest |
| 3 免打扰群不通知但未读增加 | 通过 | 用户把 litetest 设成免打扰，重启 App 后状态同步。机器人发消息，未读 0→1，灰色角标，没有发通知 |
| 4 历史加载、往上翻、手机未读清掉 | 通过 | 往上翻到了群的第一条消息。在 App 里打开 litetest 后，服务端未读 4→0（直接读 feed），用户在手机上确认角标没了 |
| 5 App 里回复，只出现一次 | 通过 | 从输入框输入并回车发送，App 和接口里都只有一条，用户在手机上确认 |
| 6 断网 2 分钟后补拉 | 通过 | 断网 130 秒，期间机器人发 3 条。恢复后 31 秒重新在线，未读 1→4（和服务端一致），补拉期间 0 条通知、0 个 `message.new` |
| 7 关窗口继续运行，退出后后端退出 | 通过 | 关窗口后 App 和后端都在，机器人消息照样弹通知。退出 App 后 1 秒内两个进程都没了 |
| 8 凭证失效进登录页并通知 | 通过 | 用删掉 `session` 的凭证副本启动，进了登录页，弹出"飞书登录已失效，请重新扫码" |
| 9 连续运行 24 小时仍在线 | 通过 | 扫码后 25.5 小时仍在线，`keepalive ok` 四次，期间没有掉登录 |

第 1 项的出入：

- **群名**：「孟骁的飞书助手」原来显示成英文名，已修（见下）。
- **未读数**：「账号安全中心」App 显示 17，官方显示 12。差的 5 条是超过保留期限的过期消息，服务端的 `newMessageCount` 算了它们，官方客户端不算。没修，已登记。
- 预览文字有小差别（链接不显示标题、部分系统消息只显示"[系统消息]"），不在验收标准里，已登记。

第 2 项的偏离：计划写的是"单聊消息"，实际用的是群里的机器人消息。单聊只差通知标题的取法，有单元测试，没有真实消息验证，已登记。

## 验收中修掉的缺陷

- **时间标签跨天不刷新**（`a959438`）：列表行的"今天/昨天"是渲染那一刻用 `Date()` 算的，过了零点没有东西触发重绘，昨天的消息还显示成几点几分。改成 `AppState.today` 在跨天、改时区、唤醒时更新，通过环境值传给各行。10 月 1 日零点实测过：不重启 App，"12:22"变成了"昨天"。
- **`backend.log` 被互相覆盖**（`bb7fb72`）：App 重启时旧后端还在写收尾日志，新旧两个写句柄各记各的偏移量，后写的盖掉先写的。改成用 `O_APPEND` 打开。
- **群名显示成英文**（`b204271`）：有的群 `name` 是英文，官方客户端显示的是 `i18nInf.i18nNames.zh_cn`。后端改成优先用它，加了 `tests/test_source_mapping.py`。
- **打开会话停在第一页开头**（`6673431`）：首次布局会短暂渲染出顶部的"加载更早"占位行，触发一次翻页；翻页后的位置恢复逻辑把视图滚到了翻页前的第一条，而不是最新消息。改成翻页时如果用户原本在底部就留在底部。时序相关，不是每次都出现。

## 修改的文件

第 2 阶段（提交 `b3faae7`、`084322b`、`e79f9cf`、`d329538`、`bec7e90`）：

- `mac/FeishuChatCore/Sources/FeishuChatCore/`：`Models.swift`（接口模型）、`SSE.swift`、`BackendEvent.swift`、`NotificationPolicy.swift`、`MessageTimeline.swift`（消息合并、翻页游标、消息行分组）、`ChatList.swift`（排序、角标数、时间格式），以及对应的测试
- `mac/FeishuChat/Services/`：`BackendSupervisor.swift`（拉起和守护后端）、`BackendClient.swift`、`BackendConfig.swift`、`NotificationService.swift`、`WindowManager.swift`、`LoginItem.swift`
- `mac/FeishuChat/Model/`：`AppState.swift`、`Conversation.swift`、`LoginModel.swift`、`BackendConnection.swift`
- `mac/FeishuChat/UI/`：`RootView`、`LoginView`、`MainView`、`ChatListView`、`ConversationView`、`ComposerView`
- `mac/FeishuChat/App/`、`mac/project.yml`、`mac/Config/Backend.xcconfig`：App 入口和后端路径配置
- `mac/AGENTS.md`、`AGENTS.md`、`kb/known-issues.md`、`kb/next-up.md`、计划第 11 节

第 3 阶段：

- `mac/FeishuChat/Model/AppState.swift`：加 `today` 和跨天监听
- `mac/FeishuChat/UI/MainView.swift`、`ChatListView.swift`、`ConversationView.swift`：时间标签从环境值 `\.today` 取"现在"；翻页后的滚动位置
- `mac/FeishuChat/Services/BackendSupervisor.swift`：日志文件用 `O_APPEND` 打开
- `backend/src/feishu_lite/source.py`、`backend/tests/test_source_mapping.py`：群名优先用中文名
- `kb/known-issues.md`：删掉保活条目，加了四条验收发现；`kb/next-up.md`：24 小时检查换成 7 天检查
- `AGENTS.md`、`mac/AGENTS.md`、计划第 11 节：验收结论和两条新规则

## 注意事项

验收方法：

- **要"别人发的消息"就用群机器人。** litetest 里的自定义机器人发的消息 `isBadged` 为真，会计未读、会触发通知。`tmp/bot_send.sh <文本>` 发送，webhook 在 `tmp/bot-webhook`。
- **别的飞书客户端开着测试群，会把未读悄悄清掉。** 用户电脑上另一个飞书窗口停在 litetest，机器人消息一到就被它标成已读，App 这边的未读要等下一次 feed 对账才归零，看起来像 App 的问题。测未读之前让用户把其他客户端切走。
- **未读数要直接问服务端。** 第二个后端实例的 `/chats` 读的是它自己的缓存，别的端标已读之后最多 5 分钟才更新。`tmp/server_unread.sh` 直接拉 feed，打印 `newMessageCount` 和 `readPosition`。
- **点通知横幅**：横幅在 `NotificationCenter` 进程的 "Notification Center" 窗口里，路径是 `group 1 of scroll area 1 of group 1 of group 1`，支持 `AXPress`。这个窗口不是普通窗口，`cua` 的 `list_windows` 看不到，要用 `osascript`（`tmp/nc_press.applescript`）。横幅只停留约 5 秒，脚本要先等它出现。
- **已读只在 App 处于前台时才标。** 用辅助功能接口在后台选中会话不会标已读，要先 `activate`。用户在用电脑时焦点很快会被切走，检查要紧跟着做。
- **弹给用户看的测试要先打招呼。** 第 8 项用凭证副本弹出的"登录已失效"通知和登录页跟真的一样，用户当场扫码确认了，账号因此多了一个网页端登录设备。这条已写进 `AGENTS.md`。顺带得到一个事实：在另一个数据目录里再扫码登录，不会把正式凭证挤下线。
- **熄屏会让截图和 GUI 自动化静默失效**，前台进程会变成 `loginwindow`。先 `wake-screen`，长时间验收挂一个 `caffeinate -d -t 1800`，用完关掉。
- 这台机器的 zsh 里 `ls` 是 `eza` 的别名，`ls -t` 会报错；`log` 是内建命令，查系统日志要写 `/usr/bin/log show`。info 级别的日志不落盘，要查的东西用 `notice` 级别打。

代码层面：

- **SwiftUI 里显示相对时间，"现在"必须是视图的输入。** 在 `body` 里直接用 `Date()` 算"今天/昨天"，过了零点不会重算。规则写在 `mac/AGENTS.md`。
- **`LazyVStack` 加 `defaultScrollAnchor(.bottom)` 的首次布局会短暂经过顶部**，放在顶部的"滚到这里就加载"占位行会被触发。靠 `onAppear` 触发翻页的地方要考虑这一点。
- **多个进程写同一个日志文件要用 `O_APPEND`。** `FileHandle(forWritingTo:)` 加 `seekToEnd()` 只在打开那一刻定位，之后各写各的偏移量。
- **`@Observable` 类里标了 `@ObservationIgnored` 的属性，视图不能直接或间接依赖**，否则收不到变化（第 2 阶段消息区一直转圈就是这个原因）。规则在 `mac/AGENTS.md`。
- **通知授权被错过一次就不会再弹。** 首次启动的授权弹窗被忽略后，系统留下"不允许"的记录，`requestAuthorization` 直接报错。通知设置现在存在 `~/Library/Group Containers/group.com.apple.usernoted/` 下，不在 `com.apple.ncprefs` 里（`tmp/ncprefs.py` 能读）。App 因此加了侧栏底部的提示条。

实测到的数字：

- 消息从发出到 App 收到 0.9 到 1.2 秒，通知在 1.5 秒内发出。
- 断网后约 40 秒后端进入"正在重连"；网络恢复后最多再等 30 秒（退避间隔的上限）。
- 9 月 30 日凌晨 01:59 到 05:28 推送连接断了 13 次，间隔约 17 分钟，报 `keepalive ping timeout`，每次 1 秒后重连成功。间隔这么规律，推测是电脑睡眠期间的周期性唤醒，没有验证。

## 对计划的改动

计划第 0 节要求说明标了"计划作者"的决定有没有改。

**决策表里的四项（后端守护方式、本地通信、App 命名、已读策略）都没改。**

执行中改了的是计划正文里的做法，前七条的理由在计划第 11 节「执行中改动的决定」：

- 保活：扫码拿到的 `session` 不是 JWT，csrf 接口不刷新它。改成每 4 小时 csrf 加 ticket 探活。
- 推送循环：没用 larkx 的 `connect_websocket`，用它的零件自己写了接收循环。
- Source 接口：`send_text` 返回发出去的 `Message`，`pull_history` 直接收 positions 列表。
- SSE 的测试：起真实的 uvicorn 加 httpx，不用 TestClient。
- 加了每 5 分钟一次的 feed 对账，因为别的端读了消息不会推送过来。
- 未读计数规则：只有"非本人、`isBadged`、position 更大"的推送才加 1，其余以 feed 为准。
- 后端跟随 App 退出：靠 `FEISHU_LITE_PARENT_PID` 每 2 秒检查一次。
- **Core 包的范围比计划大。** 计划说只放模型、SSE 解析、通知策略三样，实际多放了消息合并、翻页游标、会话排序、时间格式、消息行分组。这些是纯逻辑，放在 App target 里没法测。
- **计划之外加的功能**：通知权限被拒时的提示条、登录页上的"登录已失效"提示、正文里的网址可点击、会话已读后自动清掉通知中心里它的通知。
- **"开机启动"验证后关回去了。** 勾选后登录项注册成功；这是系统级设置，留给用户自己开。

## 遗留问题

没有未通过的验收项。下面这些都已同步到 `kb/known-issues.md` 或 `kb/next-up.md`：

- 未读数算进了超过保留期限的消息，比官方客户端多（账号安全中心 17 对 12）。
- 系统消息和卡片标题是英文的；会话列表预览里链接不显示标题。
- 单聊消息的通知没有用真实消息验证过。
- 刚打开会话时可能多拉一页历史，只修了它造成的滚动位置错误。
- 凭证只验证到 25.5 小时，更长的有效期未知，`kb/next-up.md` 里排了 7 天检查。
- 第 8 项测试时用户扫了码，账号多出一个网页端登录设备，凭证副本已删。想清掉可以在手机飞书的登录设备管理里移除。
- litetest 在验收时被设成了免打扰，还留着两个机器人（自定义机器人、notifier），需要用户自己决定要不要改回去。

后续建议（没做，没有加进 `kb/todo.md`，由用户决定）：

- 加 `make install` 和 Release 构建，让 App 不依赖仓库路径运行。
- 免打扰的群里被 @ 时照常通知，和官方客户端一致。
- 重连退避上限从 30 秒降下来，断网恢复后能更快上线。
- 未读数减掉过期消息。

## 已解决的已知问题

- **保活：扫码会话的有效期和续期方式没有验证**。2026-09-29 22:27 扫码，到 2026-10-01 00:01 共 25.5 小时一直在线，每 4 小时一次的 csrf 加 ticket 探活成功四次，期间正式凭证没有掉过登录（日志里 11:53 那条 `logged out` 来自凭证副本的失效测试）。00:00 的机器人消息 0.9 秒到达。证据 `tmp/2026-09-29-feishu-chat-mvp/accept9-24h-check.log`。

## 相关文档

- [FeishuChat MVP 计划](../plans/2026-09-29-feishu-chat-mvp-plan.md)：按它实现和验收，第 11 节补了第 3 阶段的结论
- [协议探路笔记](../notes/2026-09-29-protocol-spike.md)：参考，feed 字段和推送字段的含义
- [调研笔记](../notes/2026-09-29-feishu-chat-access-research.md)：参考，为什么走逆向网页版协议
