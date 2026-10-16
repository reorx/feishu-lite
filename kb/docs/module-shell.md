---
created: 2026-10-13
updated: 2026-10-14
tags:
  - app
  - messages
  - email
---

# Messages / Email 模块外壳

给使用或维护 FeishuLite 的人：两个模块如何切换，以及切换对聊天未读和通知有什么影响。

窗口最左侧固定显示 Messages、Email 入口，右侧显示当前模块的列表和详情。Email 已有独立配置、同步状态、收件箱列表与正文；主要配置/阅读 UI 与实际 WebKit 隔离已经 F1 验证，测试 UUID 双配置真实钥匙串隔离已通过 [F2c验收](../sessions/2026-10-14-email-keychain-chat-f2c.md)，历史 ACL、真实系统错误和剩余 UI 项仍待验。聊天扫码页只占 Messages 工作区；停留 Email 时不会启动扫码。稳定合成服务下的隐藏取消往返、假扫码状态、邮箱认证失败/HTTP 超时期间聊天历史、实际键入后点击发送与草稿已由 F2c 验证；不代表真实飞书登录或 IME/Return 键盘路径通过。后端运行依赖缺失时，仍显示全局安装引导；旧后端缺少 mail 能力时 Email 提示更新后重新检测。

切换模块会重建右侧工作区，聊天状态与后台同步继续存在。这样聊天输入框随工作区退出，Email 页不会保留隐藏输入框的键盘焦点。选中的会话和草稿保存在内存；列表与聊天详情按可见条目标识记录滚动锚点，邮件纯文本用只读原生文本并在实际布局后恢复文字位置，邮件 HTML 用公开 WebKit interactionState 和最近8封的内存文档会话缓存，重建WK时重新供应正文。当前模块会保存，重启后恢复；草稿和滚动锚点不跨 App 退出保存。聊天滚动落点和 Email 配置页键盘隔离已通过 B 独立验收；F1 已验证邮件列表锚点与新阅读界面的键盘隔离，HTML 切模块和切另一封返回的段落落点、新内存文档隔离均已通过 [F1b独立复验](../sessions/2026-10-14-email-reader-f1b-acceptance.md)，HTML无回顶或位置串用；纯文本回顶P2经 [F1c独立复验](../sessions/2026-10-14-email-reader-f1c-acceptance.md)关闭：两轮模块恢复、邮件往返、拖宽换行、深浅色、选择复制和只读输入有屏幕证据；真实中文组字及精确旧layout回放仍未验。报告同时列出部分精确竞态和系统集成的未验边界。原主要矩阵见 [F1 报告](../sessions/2026-10-14-email-reader-f1-acceptance.md)。

只有 App 激活、主窗口可见、当前处于 Messages 且所选会话加载成功，聊天才自动标为已读。看 Email 时，旧选中的聊天收到消息仍保持未读，符合原有规则的消息也会提醒。切回 Messages、返回前台或窗口成为当前窗口时，会补判所选聊天的已读。本人消息、免打扰和不计未读消息的通知规则沿用原有行为。

导航的两个 badge 各显示领域计数，Dock 汇总两者。聊天计数排除免打扰会话，隐藏会话仍计入；Email 取整个收件箱的未读快照，离线/认证失败保留旧值并提示过期，移除或更换账号清零。零不显示，超过 99 显示 `99+`，内部保留真实计数。切换模块本身不会清零计数。

邮件正文只有在当前视图成功显示、App 激活、主窗口可见且正在 Email 时才提交已读。加载、失败、后台刷新、切走后的旧完成回调不能提交；回到前台或切回 Email 会补判。离线保留缓存阅读和旧计数，不排离线写队列；失败或未确认已读可手动重试，自动操作去重。

点击通知先切到对应模块并打开窗口，再选中目标。聊天和邮件的通知目标分开标识，邮件目标包含账号和文件夹；聊天已读只清理同一聊天的通知。升级前已递送的聊天通知继续可点击和清理。Email 通知目标保存在外壳的 `pendingMailRoute`，自动等待后端能力和邮箱身份后合并调用 `loadPendingMailRoute()`；重复点击只消费最新路由。页外目标按 id 取得缓存摘要和正文，失效目标回收件箱并提示。可见性读取 `mail.displayedBodyRoute`，待跳转或裸选择不能充当已显示/已读证据。

邮件提醒按后端稳定批次处理，成功投递或明确抑制后才确认；当前 Email 只抑制同一封成功显示的正文，其他邮件及自己发给自己的收件仍提醒。读删、重建和账号移除清理对应邮件通知。投递结果不确定时保留待提醒与恢复入口，不自动重弹或确认；明确再次提醒可能重复显示。恢复提示在收件箱列表和详情上方占独立空间，文字可换行，重试按钮保留完整尺寸；没有提示时不占空间。唤醒经同一本机后端合并重连，再对账计数/提醒与可见已读。以上调用点已通过自动测试；实际系统通知、恢复提示布局与睡眠行为留独立验收，见 [E 报告](../sessions/2026-10-14-email-notifications-e.md)。

相关代码：[外壳状态](../../mac/FeishuLite/Model/AppState.swift)、[聊天状态](../../mac/FeishuLite/Model/MessagesState.swift)、[策略与路由](../../mac/FeishuLiteCore/Sources/FeishuLiteCore/ModuleShell.swift)。验证见 [Core 行为测试](../../mac/FeishuLiteCore/Tests/FeishuLiteCoreTests/ModuleShellTests.swift) 和 [实际状态调用测试](../../mac/Tests/FeishuLiteStateTests/ModuleIntegrationTests.swift)；完整范围见 [邮箱阅读器计划](../plans/2026-10-13-email-reader-plan.md)。
