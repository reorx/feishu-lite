---
created: 2026-10-08
tags:
  - macos
  - chat-management
---

# 会话多选管理与持久化隐藏

## 概要

会话列表新增「管理」：第一次点击进入复选框多选模式，再次点击展开菜单，可查看隐藏会话、全选、取消全选或完成管理。选中后点击「隐藏」，会话从主列表移入隐藏列表；新消息、重连刷新、改名或重启不会解除隐藏。隐藏列表提供「返回」和批量「取消隐藏」。已通过真实界面将账号安全中心、云文档助手隐藏，重启后确认仍只有这两个会话被隐藏。

## 修改的文件

- `mac/FeishuChatCore/Sources/FeishuChatCore/ChatList.swift`：按 ID 分出普通和隐藏列表，保留完整数据及原排序。
- `mac/FeishuChatCore/Sources/FeishuChatCore/HiddenChatPreferences.swift`：UserDefaults 按用户 ID 持久化隐藏 ID 集合。
- `mac/FeishuChatCore/Tests/FeishuChatCoreTests/HiddenChatsTests.swift`：消息更新、完整刷新、改名、恢复排序、未读不变、重建偏好实例和账号隔离的行为测试。
- `mac/FeishuChat/Model/AppState.swift`：加载/保存账号偏好，发布两套可观察列表，隐藏当前会话时清除选择并保留草稿；通知打开隐藏会话时进入隐藏列表。
- `mac/FeishuChat/UI/{ChatListView,MainView}.swift`：管理模式、菜单、批量操作、隐藏列表导航和标题。

## 验证

- BDD：先添加测试，确认缺少实现导致失败；实现后 `cd mac && make test`，50 项全部通过。
- `cd mac && make build` 成功；已通过 `make run` 启动新版。
- 真实 UI：多选两个指定会话 → 隐藏 → 管理菜单查看隐藏列表 → 取消隐藏云文档助手 → 返回并重新隐藏；管理选择不打开消息详情。
- 真实消息：临时隐藏 litetest，在该群用自定义机器人发送验收消息，确认缓存及隐藏列表更新，主列表仍无 litetest；验收后恢复 litetest。
- 重启 App 后，主列表不显示两个指定会话，隐藏列表恰好包含它们；返回操作正常，App 最终停在主列表。
- 截图及 AX 验收记录：`tmp/2026-10-08-hidden-chats/`（gitignore）。
- 已运行 `mac-dev-cleanup --only browser --min-age 2`，无测试浏览器资源待清理；未启动模拟器。

## 注意事项

隐藏是本机、按账号保存的列表偏好，不影响飞书服务端、未读数、Dock 角标或原通知规则。隐藏 ID 不随全量列表刷新清理，暂时不在后端返回列表里的会话再次出现时仍会隐藏。没有把指定名称写成程序默认规则，用户可随时取消隐藏。

## 到期检查

`kb/next-up.md` 的登录超过 7 天检查已完成：App 在线，后端日志持续有 `keepalive ok`（最近一条为 2026-10-08 15:11），未发现新增登录失效记录，本次 litetest 机器人消息通过实时链路显示。已删除该待办。该结果验证当前登录状态和消息链路，并非保证任意情况下凭证永久有效。

## 遗留问题

本次功能无遗留问题；已有图片真实下载等待验收等问题不属于本次范围。
