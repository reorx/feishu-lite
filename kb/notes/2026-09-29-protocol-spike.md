---
created: 2026-09-29
tags:
  - feishu
  - reverse-engineering
  - larkx
  - spike
---

# 第 0 阶段协议探路结果（larkx @ 2cb4f90）

用真实账号扫码登录后逐项实测。探路脚本在 `tmp/spike/`（不提交），脱敏样本在 `backend/tests/fixtures/render_cases.json`。本文不含真实人名、消息内容和 id。

## 结论速览

| 项 | 结果 |
|---|---|
| 扫码登录 | 通。`QrLogin` + `finish()`，手机扫码确认后几秒拿到凭证。手机端和其他端都没有被踢下线（用户确认） |
| WebSocket 推送 | 通。消息约 1 秒内到达（cmd 6），包括本人在手机上发的消息和本端 `send_msg` 发的消息 |
| 历史 | `messages.PullMessagesByPositionsRequest` 通；`messages.PullChatMessagesRequest`（cmd 7）在网页网关上返回 HTTP 400，不能用 |
| 发送 | 通。`PutMessageResponse` 里带完整的 `message`（id、position），手机上能看到 |
| 标已读 | `messages.PutReadMessagesRequest {chatId, maxPosition}` 通，响应里有 `readPosition`、`newMessageCount` |
| feed | `feed.PullFeedCardsRequest` 一次调通，见下 |
| 保活 | 计划里的前提不成立，见下 |

## feed（会话列表）

请求：`{type: 1 (INBOX), pullType: 1 (REFRESH), count: N, withMessageEntity: true}`，翻页用 `pullType: 2 (LOAD_MORE)` 加上一页返回的 `nextCursor`。

响应：
- `cards`：已按 `rankTime` 倒序，这个顺序就是客户端会话列表的顺序。`card.type` 为 1 (CHAT) 的是会话，其他类型有 5 (BOX，会话盒子)、3 (DOC)、13 (APP_FEED) 等，MVP 只显示 CHAT。
- `chats`：以 chat id 为键的 `entities.Chat`。
  - 未读数：`newMessageCount`（等于 `lastMessagePositionBadgeCount - readPositionBadgeCount`，也基本等于 `lastMessagePosition - readPosition`）。
  - 免打扰：`isRemind == false`（`userSetting.isRemind` 同值）。
  - 位置：`lastMessagePosition`、`readPosition`，`lastMessageId`。
  - 群名在 `name` 里；**单聊没有 name**，`key` 形如 `<用户id>:<用户id>`，去掉本人 id 就是对方 id。
- `messages`：以 message id 为键的最后一条消息实体，大部分会话都有，少数缺失。

单聊对方的名字用 `chatters.PullChattersByIdsRequest {chatterIds: [...]}` 批量查，返回 `name`，有备注时 `alias` 非空（应优先显示 alias）。机器人也能查到（`type == 2`）。本人名字同样用这个接口查。

按 id 拉单个会话：`chats.PullChatsByIdsRequest {chatIds: [...]}`（larkx 的 `get_chat_info`），推送来自本地没见过的会话时用。

## 推送（WebSocket）

- 除了 cmd 6（`PushMessagesRequest`），15 分钟里只见到 cmd 200（心跳回包）、7001/7017（设备在线状态）、95（`PushChatters`，内容为空）。没有 feed 推送（1002），也没有已读状态推送：**别的端读了消息，本端只能靠重新拉 feed 才知道**。
- 同一条消息可能推两次（图片消息实测推了两次，id 和 position 相同），必须按 message id 去重。
- 消息实体有 `isBadged`（系统消息为 false，不计未读）、`fromType`（1 用户、2 机器人）；`PushMessagesRequest.messagesAtMe` 标记 @ 我的消息。
- 决定：不用 larkx 的 `connect_websocket`，在我们自己的事件循环里用 larkx 的零件（`build_ws_url`、`send_ack`、`heartbeat_loop`、`proto_pb2`）重写一个 30 行的接收循环。理由：它在协程里同步调 `get_ticket`（阻塞事件循环），回调被扔到 larkx 自己的线程里，还丢掉了 content 原始字节和 `isBadged`；自己写就不需要跨线程切回主循环。

## 消息内容渲染

- 文本（type 4）和富文本（type 2）的正文是一棵元素树：`richText.elementIds` 是根，`childIds` 是子节点。常见 tag：1 TEXT、3 P（段落）、5 AT、6 A（链接）、27 OL、26 UL、28 LI、2 IMG、10 EMOTION。larkx 的 `extract_rich_text` 把字典平铺遍历，**列表和段落的顺序会乱**，所以 `render.py` 自己按树遍历。
- AT 元素的 property 是 `RichTextElement.AtProperty {userId, content}`，`content` 自带 `@`。各种 property 的类定义在 `lark_all_pb2.entities.RichTextElement.*`。
- 富文本的 `text` 字段是 HTML，不用。
- 系统消息（type 6）是 `messageTemplate` 加 `contents` 填空，模板是英文的（例如 `{from_user} started the group chat.`）。
- 卡片标题在 `cardHeader.title`；文件名在 `FileContent.name`。

## 凭证与保活

- 扫码登录拿到的 cookie 只有 `session`、`session_list`、`passport_web_did`、`passport_trace_id`、`login_recently`。**没有 `sl_session`，`session` 也不是 JWT**（50 个字符的不透明串），所以调研笔记里"sl_session 12 小时过期、靠 csrf 续期"的说法不适用于扫码会话，服务端有效期未知。
- `POST https://internal-api-lark-api.feishu.cn/accounts/csrf`（larkx 里的 `CSRF_URL`；`accounts.feishu.cn` 同路径返回一样）返回 200，Set-Cookie 只有 `swp_csrf_token`（15 天）、`t_beda37`（15 天）、`QXV0aHpDb250ZXh0`（1 年），不会刷新 `session`。
- 保活方案因此改成：每 4 小时调一次 csrf 并把所有 Set-Cookie 合并存盘，再用 ticket 接口探活。能否撑过 24 小时要靠 `kb/next-up.md` 里的检查来验证。
- 凭证失效的表现：ticket 接口返回 `{'message': 'session is not valid'}`（larkx 抛 `AuthExpired`）；网关接口返回 **HTTP 401**。网络不通时 larkx 的 `validate()`/`require_valid()` 也会报失败并抛 `AuthExpired`，**不能直接拿它判断登录失效**，否则断网会被误判成掉线登出。

## 未确认

- 登录设备列表里新会话显示成什么：用户确认没有被踢下线，但没看设备名。
- `session` 的服务端有效期。
