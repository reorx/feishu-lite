---
created: 2026-10-13
tags:
  - email
  - messages
  - swiftui
  - phase-b
---

# 邮箱阶段 B：双模块外壳与聊天状态拆分

## 概要

按协调文档「当前任务 B」，在 master 完成 Messages / Email 外壳、MessagesState 拆分、统一可见性/未读/通知路由。Email 是明确的待接入占位，没有 MailState、IMAP 或邮箱配置实现。自动测试和 Debug 构建通过；本执行者未启动 UI 实机验收，B 的 UI 签收由 coordinator 分派独立 tab。

AppState 持有后端、一条 SSE、模块选择、全局时间与汇总 badge；MessagesState 持有聊天登录、列表、隐藏偏好、当前会话、草稿及滚动锚点。RootView 用条件分支重建工作区，切到 Email 撤掉输入框焦点并停止扫码任务，聊天同步继续。当前模块保存在 UserDefaults 的 `active-module`，草稿、选择、锚点仍仅存内存。

## 修改的文件

- `mac/FeishuChatCore/Sources/FeishuChatCore/ModuleShell.swift`：AppModule、ViewingContext、UnreadCounts、NotificationRoute；路由支持单封邮件与收件箱汇总目标，兼容旧 chat_id 通知。
- `mac/FeishuChatCore/Sources/FeishuChatCore/BackendError.swift`、`Models.swift`：仅精确的 409 + `detail=logged_out` 映射聊天登出；BackendStatus.features 缺失或 null 时解码成空数组。
- `mac/FeishuChat/Model/AppState.swift`、`MessagesState.swift`：外壳与聊天拆分，一条 SSE 分派；未读变更回调接入全局唯一 badge 写入入口。
- `mac/FeishuChat/Model/LoginModel.swift`：快速切换导致旧任务覆盖新任务句柄的竞态修复；世代校验与 await 后取消检查。
- `mac/FeishuChat/Services/BackendClient.swift`、`NotificationService.swift`、`WindowManager.swift`：实际 HTTP 分类接入、通知领域命名空间和清理、窗口/通知隔离测试接口。
- `mac/FeishuChat/UI/{RootView,MainView,LoginView,ChatListView,ConversationView,ScrollAnchors,ComposerView,ImageMessageView}.swift`、`App/FeishuChatApp.swift`：76 pt 窄导航、模块占位、聊天登录局部化、列表/详情可见行锚点、原生输入框拆除焦点释放、菜单绑定迁移；LoginView 不再自行无条件 begin，扫码统一由 MessagesState 控制；ImageMessageView 增加 Core import 以继续匹配 BackendError。
- `mac/FeishuChatCore/Tests/FeishuChatCoreTests/ModuleShellTests.swift`：先写 Core 的新契约行为测试。
- `mac/Package.swift`、`mac/Tests/FeishuChatStateTests/ModuleIntegrationTests.swift`、`mac/Makefile`：直接编译 App 的 Model/Services，自动验证真实调用点；make test 运行 Core 和状态调用两套测试。
- `AGENTS.md`、`mac/AGENTS.md`、`README.md`、原计划、`kb/docs/module-shell.md`、`kb/known-issues.md`：当前状态、开发入口与未验事项同步更新。未修改协调文档。

## 行为测试证据

在 `mac/` 执行 `make test`、`make build`，最终均退出 0。Core **65 个测试**通过（原有 52 + 本次 13 个参数展开后的用例）；App 实际状态调用 **5 个测试**通过。Debug 构建 `Build Succeeded`。Python 后端没有修改，本阶段未运行后端测试，也未增加 IMAP 依赖。

本 checkout 的日志归档目录为 `tmp/2026-10-13-email-shell-phase-b/`（gitignored，无截图）：

| 证据 | 结果与边界 |
| --- | --- |
| `tests-red.log` | 新契约实现前的 make test 失败：AppModule / ViewingContext / NotificationRoute 等尚不存在，属于编译期红灯，不冒充运行期断言失败 |
| `tests-state-red.log` | 真实 App 调用测试在 BackendClient 尚无 session 注入接口时编译失败 |
| `login-race-red.log` | LoginModel 原实现的运行期失败：begin/end/begin 后再 begin，QR 请求由 2 增为 3，旧任务错误释放新任务句柄 |
| `tests-final.log` | 65 Core + 5 App 调用测试全部通过，含上述扫码竞态修复后的回归 |
| `build-final.log` | 最终 Debug 构建成功，未运行 App |

自动测试覆盖：Email 下旧选中聊天加载完成、收到新消息、重连刷新、补判已读均不发 read 请求，未读仍为 2，通知 recorder 收到一次；切回 Messages 后恰好发一次 read、清理聊天通知，未读为 0。Conversation 实例、草稿和状态中的锚点保持，**这里只验证状态保留，未验证原生视图实际滚动落点**。

其他用例覆盖前台/窗口可见条件、正文成功与邮件目标一致性、QR 登录只属 Messages、路由编解码/旧通知兼容/非法目标、领域通知 id 隔离、两模块真计数及 0/99/99+、旧后端缺失 features、不同 409/401/畸形响应，以及实际 Conversation 对非聊天 409 显示错误。AppState.open 经窗口 recorder 验证模块切换和目标保存，不激活真实 App；持久化测试使用独立 UserDefaults suite，结束删除该 suite。

## 实际接入位置与 C/D 接口

| 入口 | 当前接入与后续约定 |
| --- | --- |
| `MessagesState.received` | 实时消息使用 ViewingContext 决定本地清零/read；NotificationPolicy 取同一快照的 notificationContext，Email 不抑制旧选中聊天通知 |
| `MessagesState.markReadIfViewing` | 点击聊天加载完成、重连加载完成、落后历史补拉及返回窗口共用；检查模块、前台、窗口、选中项和 hasLoaded |
| `AppState.reevaluateViewing` | activeModule 改变、App 激活、窗口成为 key、工作区出现、通知路由后调用；D 在此补 MailState 成功正文的已读判断 |
| `AppState.runEventLoop/handle` | 唯一 SSE；当前分派全部现有聊天事件。C3 增加 mail.* 解码，D 在 handle 分派邮件事件；连上后的邮件刷新必须独立于 MessagesState.isLoggedIn |
| `AppState.updateUnread(messages:email:)` | 唯一 setBadge 调用点，保留未更新的另一领域计数；MessagesState.onUnreadCountChange 已接入。D/E 上报整箱邮件数，不能从当前页或事件累加 |
| `AppState.open(_:)` | 按 NotificationRoute.module 切换、显示窗口，再处理聊天目标；邮件保存为 pendingMailRoute，尚不加载或标已读 |
| `AppState.viewingContext` | 当前聊天来自 MessagesState.selectedChatID；邮件目标暂用 pendingMailRoute。D 必须改为 MailState 当前实际选择，**pending route 不是正文成功显示的证据**，并消费/清除待处理目标 |
| `NotificationRoute` | userInfo.domain 为 messages / email；邮件带 mail_account_id、folder_id、可选 message_id（nil 为汇总）。C 后端的 mail 域仍叫 mail，不需把 SSE 名称改成 email |
| `NotificationService` | 通知 identifier/thread 用领域+编码组件；旧 chat_id 可点击/清理；clearNotifications(chatID:) 按解码目标过滤，不碰邮件通知。后续邮件递送、清理/ack 仍未实现 |
| `BackendStatus.features` | 旧字段不变，features 默认 []；C3 加后端 features，D 用它判断旧版本并显示安装命令。B 不因缺少 mail 功能显示连接错误，统一显示待接入占位 |
| `MessagesState` 锚点 | listScrollAnchors 按可见/隐藏列表分开；detailScrollAnchors 按 chat id 分开；切换模块不换 Conversation，账号变更或登出会清除状态。D 的 MailState 自持自己的锚点 |

## 自主决策与偏离

- 保留原有 macOS 原生视觉和 NavigationSplitView，增加 76 pt 导航，最小窗口宽度由 720 改为 800 pt，使原工作区宽度仍有约 720 pt；最小尺寸的视觉结果待验。
- macOS 14 的 List 使用行几何与 viewport 相交判断首个可见条目，再由 ScrollViewReader 恢复；详情保留底部特殊锚点，使停在底部时继续跟随新消息。未升级最低系统版本，未引入新 UI 框架。
- 增加独立的 mac/Package.swift 状态测试包，Core 保持无 AppKit。App 测试直接编译生产源码，网络走 URLProtocol，通知和窗口走 recorder，避免仅测纯函数却遗漏实际接线。
- 扫码任务竞态是本次频繁模块切换暴露的相关修复；先运行失败复现测试再修，没有扩展到其他聊天网络/生命周期重构。
- 本任务未实现邮箱读取、凭证注入、旧后端安装提示、mail.* SSE 或邮件通知；都在 C/D/E 的既定边界内。未访问真实邮箱、凭证文件或钥匙串，没有发送任何真实聊天/邮件。

## 验收交接与遗留问题

coordinator 下一步安排**独立 B 隔离 UI 验收**，本执行者不自行启动。原计划 B 的 UI 与聊天整体可用性回归两项未勾选；known-issues 已记录本阶段切换行为待验。

1. 在隔离聊天中选中会话，输入草稿，滚动会话列表和详情到中间；切 Email 打字、连续回车/Shift+回车，不应发送聊天或改变草稿。返回 Messages 时还原草稿、选中项、两处首个可见行；追加新消息与翻页不能错误跳到底。
2. 测最小 800 × 460、拖宽、导航选中态、0/99+ badge、标题随模块改变；重启恢复 Email 后不请求聊天 QR。主后端依赖缺失仍可显示全局安装引导。
3. 在 Email 收旧选中聊天的新消息，应保留未读、按原通知策略提醒；返回 Messages、重新激活或重新打开窗口后补已读。用隔离后端检查 read/发送计数；若要真实消息，只能用用户授权的 litetest，不能点击工作会话。
4. 回归聊天扫码、历史翻页、发送/输入法、隐藏/取消隐藏、图片预览/失败重试、通知点击（包括升级前通知）、关窗常驻及后端重连。截图放验收执行者的 `tmp/<日期>-email-reader/`，由其记录实测证据。

未新增浏览器、模拟器、本地服务端、IMAP 连接或后台探路进程。状态测试中的扫码任务均取消；UserDefaults 测试 suite 已删除。测试/构建进程已退出，不需对用户正在使用的 App 执行 mac-dev-cleanup。未 push、未发布、未开新分支/worktree、未委派其他 agent、未启动 C 或 UI 验收。

## 相关文档

- [串行协调与任务 B](../plans/2026-10-13-email-reader-coordination.md) — 本次执行边界，阶段签收由 coordinator 更新。
- [邮件阅读器计划](../plans/2026-10-13-email-reader-plan.md) — 实施依据，仅勾选 B 有自动证据的项目。
- [IMAP 探路笔记](../notes/2026-10-13-email-imap-probe.md) — 已读 A 的后续约定；本次没有实施 IMAP。
- [模块外壳说明](../docs/module-shell.md) — 新建的当前用户行为说明。
- [已知问题](../known-issues.md) — B 切换行为的独立 UI 验收待办。
