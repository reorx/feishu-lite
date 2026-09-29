---
created: 2026-09-29
tags:
  - feishu
  - research
  - reverse-engineering
  - openapi
---

# 飞书聊天接入调研：官方 API vs 逆向网页版协议

目标：不开飞书官方客户端，用自己的轻量客户端收发本人账号的全部消息（单聊 + 群聊）。账号在公司租户下，本人是租户管理员，租户是**基础免费版**。

结论：选了**逆向网页版协议**（LarkAgentX 的 `larkx` 包）。官方 API 在免费版额度下做不到单聊 1 分钟内通知。

## 官方 OpenAPI（open.feishu.cn）

- 2026-04-10 起，`im/v1` 的获取历史消息、获取单条消息、发送、回复都支持 `user_access_token`，能读本人和真人的单聊。需要的 scope：`im:message.p2p_msg:get_as_user`、`im:message.group_msg:get_as_user`、`im:message.send_as_user`。
- **没有用户身份的 IM 事件。** `im.message.receive_v1` 只推给机器人。用户身份能订阅的事件只有云文档、日历、邮箱。单聊只能轮询。
- 会话列表（`GET /im/v1/chats`）不返回未读数和最后一条消息，也没有 feed 或未读数接口。官方 lark-cli 靠一个未公开的 `types=p2p,group` 参数把单聊列出来。
- **免费版额度**：同一租户下所有自建应用合计每月 1 万次，超出后返回 99991403。2026-03 起限时放宽到 100 万次，官方公告只写到 6 月，之后的状态未确认。当前用量在管理后台：费用中心 → 权益数据 → API 调用次数。
  - 每个接口是否计费可以查文档详情接口 `open.feishu.cn/document_portal/v1/document/get_detail?fullPath=...` 返回的 `apiChargingStrategy`：消息类是 `basic`（计费），`contact/v3/users/:id` 是 `none`（不计费）。已核实。
- 按 1 万次/月算，单聊轮询只能做到工作日每 90 秒一次，或全天每 5 分钟一次。
- 群聊可以把机器人拉进群，用长连接实时接收，事件推送大概率不计费。代价是所有群成员都看得见机器人。
- 官方 CLI：github.com/larksuite/cli（2026-09-28 发布 v1.0.97）。它会在你的租户里新建一个自建应用，调用计入额度。
- 飞书没有类似企业微信"会话存档"的 API。行为审计日志不含消息内容。

## 逆向网页版协议

| 项目 | 结论 |
|---|---|
| **cv-cat/LarkAgentX**（`larkx` 包，commit `2cb4f90`，2026-08-18） | 选用。纯 Python，依赖 protobuf、websockets、requests。实现了扫码登录、WebSocket 推送、历史分页、发文本、id 转名字、标已读，能解析约 20 种消息类型。**没有 LICENSE 文件**，只能个人使用，不能再分发 |
| cv-cat/OpenFeiShuApis、echowxsy/lark-cli | 是上面那个库的旧版子集，不用 |
| EthanQC/feishu-user-plugin | 读取和推送走官方 OpenAPI，会消耗额度。它的 cookie 保活做法可以借鉴（见下） |

larkx 缺的东西：

- **会话列表（feed）没封装。** schema 里有 `feed.PullFeedCardsRequest`（cmd 1000），可以通过 `client.api()` 调用。返回的 `entities.Chat` 带 `newMessageCount`、`readPosition`、`lastMessagePosition` 等字段，请求参数的语义要验证。
- **凭证不会续期。** `sl_session` 有效期 12 小时（JWT 的 exp 减 iat 等于 43200 秒）。feishu-user-plugin 的做法是每 4 小时 `POST /accounts/csrf`，把返回的 `Set-Cookie` 里的 `sl_session` 和 `swp_csrf_token` 写回去（`src/clients/user.js` 的 `_getCsrfToken`、`src/auth/cookie.js`）。larkx 的 `refresh_csrf()` 只更新了 `swp_csrf_token`。
- **WebSocket 断线不会重连，也不会补拉漏掉的消息。**
- LarkAgentX issue #11：复制浏览器 cookie 来跑，约一天就失效，网页端也一起被登出。扫码登录会建一个独立会话，理论上不受影响（推测，没有 issue 证实）。
- 登录设备列表里很可能显示成一台 Windows Chrome（代码里伪装的 UA）。管理员后台的"多端同登设置"可能按登录时间踢掉较早的网页端会话。

## 调研中排除的方案

- Matrix、matterbridge、Beeper、OpenIM：没有能以本人账号收发的飞书桥接。
- Ferdium、Rambox：只能看未读角标，本身是 Electron，比官方客户端轻不了多少。
- 读 macOS 通知中心再转发：前提是飞书客户端还开着。
