---
created: 2026-10-13
tags:
  - app
  - messages
  - email
---

# Messages / Email 模块外壳

给使用或维护 FeishuChat 的人：两个模块如何切换，以及切换对聊天未读和通知有什么影响。

窗口最左侧固定显示 Messages、Email 入口，右侧显示当前模块的列表和详情。Email 已有独立配置及同步状态，阅读列表与正文留 D2；配置 UI 与真实钥匙串尚待独立验收。聊天扫码页只占 Messages 工作区；停留 Email 时不会启动扫码。后端运行依赖缺失时，仍显示全局安装引导；旧后端缺少 mail 能力时 Email 提示更新后重新检测。

切换模块会重建右侧工作区，聊天状态与后台同步继续存在。这样聊天输入框随工作区退出，Email 页不会保留隐藏输入框的键盘焦点。选中的会话和草稿保存在内存；列表与详情按可见条目标识记录滚动锚点。当前模块会保存，重启后恢复；草稿和滚动锚点不跨 App 退出保存。滚动落点和键盘隔离尚待独立 UI 验收。

只有 App 激活、主窗口可见、当前处于 Messages 且所选会话加载成功，聊天才自动标为已读。看 Email 时，旧选中的聊天收到消息仍保持未读，符合原有规则的消息也会提醒。切回 Messages、返回前台或窗口成为当前窗口时，会补判所选聊天的已读。本人消息、免打扰和不计未读消息的通知规则沿用原有行为。

导航的两个 badge 各显示领域计数，Dock 汇总两者。聊天计数排除免打扰会话，隐藏会话仍计入；Email 取整个收件箱的未读快照，离线/认证失败保留旧值并提示过期，移除或更换账号清零。零不显示，超过 99 显示 `99+`，内部保留真实计数。切换模块本身不会清零计数。

点击通知先切到对应模块并打开窗口，再选中目标。聊天和邮件的通知目标分开标识，邮件目标包含账号和文件夹；聊天已读只清理同一聊天的通知。升级前已递送的聊天通知继续可点击和清理。Email 通知目标保存在外壳的 `pendingMailRoute`，D2 消费后才能成为真实选择；可见性读取 `mail.selectedRoute`，待跳转路由不能充当已显示/已读证据。D1 不 read/ack，E 仍负责实际邮件通知投递与精确账号清理。

相关代码：[外壳状态](../../mac/FeishuChat/Model/AppState.swift)、[聊天状态](../../mac/FeishuChat/Model/MessagesState.swift)、[策略与路由](../../mac/FeishuChatCore/Sources/FeishuChatCore/ModuleShell.swift)。验证见 [Core 行为测试](../../mac/FeishuChatCore/Tests/FeishuChatCoreTests/ModuleShellTests.swift) 和 [实际状态调用测试](../../mac/Tests/FeishuChatStateTests/ModuleIntegrationTests.swift)；完整范围见 [邮箱阅读器计划](../plans/2026-10-13-email-reader-plan.md)。
