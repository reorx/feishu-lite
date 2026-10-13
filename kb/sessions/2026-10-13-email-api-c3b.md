---
created: 2026-10-13
tags:
  - email
  - python
  - api
  - sse
  - phase-c3b
---

# 邮件 C3b：本机 API、共享 SSE 与进程生命周期接线

## 概要

在当前 master、C3a 基线 `3f755b7` 上接通全部邮件接口、共享 token 鉴权、独立 MailService/MailStore 生命周期与双领域 SSE。聊天未登录仍可配置和同步邮箱；邮件认证、超限、网络错误不触发聊天登出。先写失败行为测试，再实现 API；复查增加超时和对外 id 的失败复现后修正。最终验证结果及完整进程计时见下文。

只完成 C3b；App Email 仍是占位，没有钥匙串、阅读 UI 或邮件系统通知。未读取 env、真实缓存或账号，未访问真实邮箱、写真实 flags、发信、打开用户 App、委派、修改协调文档、push、发布或开始 D。

## 修改的文件

- `backend/src/feishu_lite/mail/api.py`：完整路由、顶层错误边界、校验防泄漏、断开取消与等待期限。
- `backend/src/feishu_lite/mail/types.py`：共享请求/错误/read 模型；摘要只读计算字段 id。
- `backend/src/feishu_lite/mail/store.py`：存摘要时排除计算字段，保持既有 JSON/schema 与旧缓存兼容。
- `backend/src/feishu_lite/api.py`：解析请求体前 token 鉴权、邮件路由、事件循环内 mail.db 创建、共享 SSE 与 lifespan 收尾。
- `backend/src/feishu_lite/{main,service,store,types}.py`：实际退出顺序、父进程 watcher 收尾、256 项有界分发队列、数据路径与 features。
- `backend/tests/mail/{test_api,test_api_imap,test_api_shutdown,api_stop_child}.py`：真实 HTTP/SSE、可控适配器、真实 IMAPClient/合成服务端与 SIGTERM 子进程证据。
- `AGENTS.md`、`backend/README.md`、`kb/docs/email-foundation.md`、原计划与本报告：实际接口及证据；原有 known-issues/next-up 不变。

无新增依赖、锁文件、App 或 IMAP 执行器改动；不运行 formatter/style linter。

## D1/D2 可直接消费的 HTTP 契约

服务仅绑定 127.0.0.1。**全部接口（含 `/events`、OpenAPI）需要 `Authorization: Bearer <launch token>`**。缺失/错误 token 为 401 `{"detail":"invalid token"}`，在 JSON 解析前拒绝，坏 JSON 也不能绕过。使用 JSON 请求体；所有 mail 成功响应均为 200，包含 `Cache-Control: no-store`。

请求模型禁止额外字段；字符串严格校验。地址长度 3..512，必须是无空白、单 @ 的地址；不对用户输入做隐式修剪。专用密码为 SecretStr，长度 1..4096，响应与 repr 不包含它。`mail_account_id`/`batch_id` 非空、最多 512 字符且无控制字符；UIDVALIDITY 为严格整数 1..4294967295，不接受 bool/字符串。

| HTTP | 请求/默认值 | 200 响应 |
| --- | --- | --- |
| GET /status | 无 | 原 `state,user,last_error` 加 `features:["mail"]`；state 仍是聊天状态。 |
| GET /mail/status | 无 | MailStatus，含持久 pending。 |
| POST /mail/account/test | `{address,password}` | `{writable:bool,supports_idle:bool}`；只试连，不保存、不配置账号。 |
| PUT /mail/account | `{address,password}` | `{account:{id,address},removed_account_id:string|null}`；相同地址沿用 id，不同地址生成 UUID。 |
| PUT /mail/account/credential | `{mail_account_id,password}` | MailStatus；只注入密码，幂等、不重置缓存/水位。 |
| DELETE /mail/account | 无 | `{account:null,removed_account_id:string|null}`；重复移除可用。 |
| GET /mail/folders | 无 | MailFolder 数组，全部 LIST 目录。 |
| GET /mail/messages | query `folder=INBOX,cursor=null` | `{items:[MailSummary],next_cursor:string|null}`；初始最多 100，后续最多 50。 |
| GET /mail/messages/{id} | 摘要的 `id`，不重新编码 | `{kind:"plain"|"html",content:string}`；仅按需正文，无 Seen 副作用。 |
| POST /mail/messages/{id}/read | 无 | `{read_ids:[string]}`；幂等；只有成功核实 Seen 才更新本地计数。 |
| POST /mail/sync | query `reconnect=false,wait=true` | MailStatus；合并正在进行的轮次。reconnect 强制换连接；wait=false 只触发。 |
| POST /mail/notifications/ack | `{mail_account_id,uidvalidity,batch_id}` | MailStatus；整批确认，未知/已确认 batch 幂等。 |

`GET body` 按 C3a 原生 MailBody 返回，邮件头和附件元数据沿用所选摘要，不重复带进正文响应。这是对草案「正文与附件」的表示调整，附件信息仍完整可取；没有附件下载接口。返回 configure/credential 不代表 online，随后读 status/SSE，或显式 sync 等待对账。列表在已配置但首次 SELECT 尚未完成时返回 not_synced；文件夹目录此时可能为空。

### 字段与样例

MailStatus 的全部字段（缺值为 null，数组为空而非 null）：

```json
{"mail_account_id":null,"address":null,"state":"unconfigured","generation":0,"uidvalidity":null,"last_sync_at":null,"unread_count":0,"unread_stale":true,"pending":[],"error":null}
```

state 为 `unconfigured / credential_missing / connecting / online / offline / auth_failed`；generation 是本进程 MailService 的连接计数，UIDVALIDITY 是服务端邮件世代，二者不能混用。last_sync_at 是 Unix 秒；unread_count 来自整个 INBOX，unread_stale 表示旧计数。error 为安全代码，不是服务器原文。

```json
{"address":"synthetic@example.invalid","password":"<专用密码，仅请求>"}
```

上例可用于 test/configure。credential 请求使用服务返回的账号 id：

```json
{"mail_account_id":"<返回的 UUID>","password":"<专用密码，仅请求>"}
```

MailSummary 全字段：`id`（只读不透明路径 id）、`key:{account_id,folder_id,uidvalidity,uid}`、`subject`、`sender`、`to`、`cc`、`date`、`message_id`、`received_at`、`size`、`flags`、`unread`、`attachments`、`body_part`、`error`。sender/to/cc 的项为 `{name,address}`；date 是邮件显示头，received_at 是 INTERNALDATE Unix 秒，size 非负，分页只按 UID。message_id 是原邮件 Message-ID，不能当 identity。body_part 是结构元数据，App 不用它构造网络 FETCH。错误占位可有空主题/发件人、received_at=0 和 error，App 给回退文案。

MailFolder：`id,name,delimiter,flags,selectable,supported`；INBOX id 统一大写，其他目录真实 id 可含中文和斜杠。首版内容仅支持准确的 INBOX，其他 folder 请求为 unsupported_folder，不能只靠 UI 禁用。

Attachment：`section,filename,media_type,encoded_size,size_is_approximate,content_id`；未知大小为 null，编码后大小不能当下载后的精确字节数。正文 html 已净化，plain 必须按纯文本显示；D2 仍要落实 WebKit 隔离。

请求/响应完整合成样本及机器可读 schema：`tmp/2026-10-13-email-api-c3b/wire-examples.json`、`openapi.json`，由可重跑的 `export_wire.py` 从真实 HTTP/SSE 导出。模型唯一源码为 mail/types.py；计算字段 id 不写入数据库，不改 user_version=2。App 可直接使用 items[].id 和 next_cursor，不需复现 canonical base64url 编码。

### 邮件错误映射

mail 响应统一为 `{"domain":"mail","code":"..."}`，没有 detail/input/body/ctx，也不含 SecretStr。校验错误包括坏 JSON、嵌套错误、错类型、额外字段，一律 422 invalid_request；不回显用户可控字段名或错误消息。其他聊天端点保留 FastAPI 默认 422 detail 格式，聊天 AuthExpired 仍为 409 `{"detail":"logged_out"}`。**邮件不返回 409，也不调用聊天登出 handler。**

| HTTP | code |
| --- | --- |
| 400 | unconfigured, account_mismatch, invalid_id, unsupported_folder, invalid_page_size |
| 403 | credential_missing, authentication_failed, mailbox_readonly |
| 404 | message_missing, folder_missing, inbox_missing |
| 410 | stale_message, stale_cursor, stale_request（重新取当前账号/列表） |
| 413 | body_too_large, response_too_large, headers_too_large, mime_too_deep, too_many_parts |
| 422 | invalid_request, malformed_mime, malformed_encoding, unsupported_charset, unsupported_transfer_encoding, unsupported_body, malformed_response |
| 502 | seen_not_persisted, command_rejected, disconnected, imap_failed, tls_failed |
| 503 | offline, not_synced, service_stopped, executor_stopped, stop_timeout, queue_full, connection_test_busy |
| 504 | command_timeout, idle_done_timeout, request_timeout |
| 500 | internal_error；未知领域 code/异常统一收敛，不回传异常文本/cause。 |

邮箱失效凭证 403 与本机 token 401 不同。离线列表/已缓存正文仍可 200，缓存 miss/显式 read 为 offline；失败 read 保留未读，不排离线写队列。旧账号邮件、旧 UIDVALIDITY、旧游标和迟到成功均拒绝，防止打开或写入新账号的同 UID。

每个邮件请求最多等待 30 秒，之后取消该调用并返回 504 request_timeout。试连取消会停止临时所有者，DNS 无句柄的清理上限再约 1.5 秒；客户端超时应留出这一收尾时间。同步取消只撤销等待者，共享轮次继续，pending 不丢；可改用 sync?wait=false，然后 GET status。超时/客户端断开不能假定 configure/STORE 没有发生，应重新取状态/列表；已经发上 wire 的 STORE 不能撤回。账号操作不回滚已经提交的改变。试连一次最多一个，忙时 503；stop_timeout 期间等待旧 owner.closed，禁止新建 DNS 所有者风暴。

## E 的 SSE 与通知确认契约

单一 `GET /events` 同时承载聊天与邮件，既有聊天 event/data 不改。连接首先发 `status` 和 `mail.status` 快照；不会重放旧 arrived。每次连上仍须分别 GET `/status`、`/mail/status`，恢复列表/计数并处理 pending。后端重启必须重置 App 的 generation 比较基线，不能用旧进程更大的 generation 拒绝新进程事件。

```text
event: mail.status
data: {"type":"mail.status","account_id":null,"generation":0,"folder_id":"INBOX","uidvalidity":null,"status":{"mail_account_id":null,"address":null,"state":"unconfigured","generation":0,"uidvalidity":null,"last_sync_at":null,"unread_count":0,"unread_stale":true,"pending":[],"error":null},"notification":null,"read_ids":[],"deleted_ids":[],"reset":false}

```

全部 MailEvent 字段为：`type,account_id,generation,folder_id,uidvalidity,status,notification,read_ids,deleted_ids,reset`，非适用 payload 为 null/[]/false。事件名和 data.type 相同：

- mail.status 的 status 是上面的 MailStatus；账号改变、上线/离线、认证失败、read/ack 更新状态。
- mail.updated 的 read_ids/deleted_ids 用于清理相应邮件通知；reset=true 使旧 UIDVALIDITY 目标整体失效，然后刷新列表/状态。
- mail.arrived 的 notification 是 `{id,account_id,folder_id,uidvalidity,mode,items}`；mode=individual/summary，items 是带不透明 id 的完整摘要，不含正文。

pending 和 arrived.notification 同模型。逐封提醒用摘要 id 作为稳定目标；汇总用 notification.id。系统 identifier 另加 mail/账号命名空间。整批投递或按 ViewingContext 抑制后才 ack：

```json
{"mail_account_id":"<该批账号 UUID>","uidvalidity":77,"batch_id":"<notification.id>"}
```

事件已入队、发送或被断开都不等于 ack；无订阅者仍先持久化。每个 SSE 订阅队列最多 256 项，满时清空并结束这个慢流，生产者不阻塞、不抛 QueueFull；客户端重新连并读取两领域快照。通知 pending 保留，不依赖历史 SSE。真实连接测试覆盖断开退订、队列满结束与重连恢复；没有系统通知投递/点击证据。

## 生命周期和停止证据

create_app 的 lifespan 在事件循环创建同目录独立 mail.db/MailStore，先启动邮件服务再启动聊天，不等待 IMAP 网络。恢复账号为 credential_missing，不读钥匙串；App 只注入同账号密码即可保留水位。退出先停止邮件服务任务，再关闭 Store；所有 SQLite/emit 仍属事件循环。网络、render-only、试连的停止继续由 C3a 并行收敛，保留 DNS stop_timeout/closed 规则。

生产 main 使用 BackendServer，关闭 listener 和 SSE 后先停止服务，再让 Uvicorn 收敛 HTTP 请求、运行 lifespan 关闭 Store。原因是默认 Uvicorn 先等待 HTTP，而卡住的试连/正文需要 MailService.stop 才能结束。HTTP graceful 剩余等待为 0.2 秒；父进程 watcher 在 _serve finally 中取消。父进程失联检测仍有既有 2 秒轮询周期，不能把该检测延迟计为 SIGTERM 停止证据。

`test_api_shutdown.py` 从父进程发送真实 SIGTERM 到整个测试子进程退出计时，不含解释器启动。子进程使用生产 create_app、BackendServer、_serve、真实 IMAPClient、loopback HTTP/SSE、合成 IMAP 服务端、临时 SQLite；退出前断言 pending future 清空、正常 owner thread 结束、Store 已关闭、无默认线程池，关闭 peer/socket/client，并在 Uvicorn 重放信号前删临时目录。DNS 为可控 getaddrinfo 样本，其他为真实本地 wire 等待；不是真实系统 resolver 或外网断线实测。

最终实际计时由 `tests-final.xml` 的 `http_stop_seconds` 记录，五项全部小于 2 秒：

| 场景 | 秒 |
| --- | ---: |
| IDLE + network/render 两所有者 + SSE | 0.202402 |
| 正文 FETCH 无响应 + SSE | 0.138825 |
| 进行中的试连 greeting 阻塞 + SSE | 0.215232 |
| 网络与试连均 greeting 阻塞 + SSE | 0.188540 |
| 网络与试连两个 DNS 无句柄所有者 + SSE | 1.684822 |

真实 HTTP 正文请求到服务端实际 FETCH 为 **0.110287 秒**（含 DONE 确认延迟），不是 mock 立即完成。独立安装 wheel 的实际 CLI SIGTERM 到退出为 **0.196554 秒**；缺 token 入口退出码 2，实际 mail/cache 数据库为 0600。

## 测试证据

证据目录 `tmp/2026-10-13-email-api-c3b/`，全部是合成样本；无 UI、无截图。CPython 3.12.12 / IMAPClient 4.1.0。最终执行 `cd backend && uv run --locked pytest -q -o junit_family=legacy --junitxml=../tmp/2026-10-13-email-api-c3b/tests-final.xml`：**297 项通过，47.42 秒，0 failure/error/skip**（C3b 新增 76 项，前序 221 项回归）。`git diff --check` 通过；未跑 App 构建或 UI/真实邮箱验收。

| 日志/产物 | 证据 |
| --- | --- |
| tests-red.log | API 行为先写，缺少 create_app 邮件接线参数，1 failed/50 errors；接线前红灯。 |
| tests-first-run.log | 首批真实 HTTP/SSE 51 项通过。 |
| tests-errors-red.log | C2 只读/网络/TLS/DONE 等 6 个映射/离线场景运行期失败，再修正为正确安全 HTTP code。 |
| tests-api-green.log、tests-wire-review.log | 中间 HTTP/完整进程与真实 IMAP wire 验证通过。 |
| tests-timeout-red.log | command_timeout 被错映射 500 的失败复现。 |
| tests-deadline-red.log / tests-deadline-green.log | 无 HTTP 等待期限导致两个场景超时，补 30 秒期限后连同 command_timeout 3 项通过。 |
| tests-wire-id-red.log | 返回摘要未交付不透明 id 的运行期 KeyError；随后加只读计算字段、保持缓存格式。 |
| tests-json-bytes-red.log / tests-json-bytes-green.log | 非法 UTF-8 JSON 被框架包装成 Starlette HTTP 400、最初误归 500；归一到安全 422 后专项通过。 |
| tests-full-first.log / .xml | 中间全量 292 项通过。 |
| tests-final.log / .xml | 最终全量回归与实际 wire/进程计时。 |
| wire-examples.json / openapi.json、export_wire.py | 全部接口和三类事件的完整合成输出、共享模型 schema；临时数据目录清理。 |
| build-final.log / install-final.log / cli-help.log / installed-smoke.json | wheel 隔离安装、CLI 和实际 installed entrypoint 启停证据。 |
| evidence-audit.json、audit_evidence.py | 日志 hash、测试数、计时、文档/修改范围和本任务资源审计。 |

API 新测试包含 token 全路由×两种拒绝、22 个 credential validation 泄漏样本（含非法 UTF-8 JSON）、意外含合成秘密 cause 的异常、认证失败与聊天 QR/实时 SSE 并存、分页/目录/正文/Seen、失败 read、离线缓存、账号切换的迟到 body/Seen、重启 credential_missing/幂等注入/pending/ack/旧世代、30 秒等待期限、真实流取消/背压/重连。真实 IMAP HTTP 测试确认 PEEK/附件元数据、显式 Seen、新信 arrived、巨大 literal 拒绝、正文入队到服务端 FETCH <2 秒。

## 自主决策、偏离与交给协调者

- 复用聊天 Service 的分发入口，而非新建长期转发 task/通用插件框架；队列改有界且满时断流。生产停止先关闭 listener/流再停止 owner，避免等 HTTP 与停 owner 互相等待。
- token 校验前移到纯 ASGI middleware，保护坏 JSON 路径；没有使用 BaseHTTPMiddleware，以保留流式行为。邮件请求有独立顶层错误边界，其他端点 validation/聊天 409 语义保持。
- 原计划接口全部实现；增加 sync 的 wait=false；GET body 不重复摘要里的头部/附件。MailSummary 对外增加 id 计算字段，Store 排除它以保持缓存兼容；没有更换 schema 或同步策略。
- 停止专项是在 API 接线后补充的完整生产进程测试；不把它写成接线前就存在的运行期红灯。其依据是已安装 Uvicorn 的实际 shutdown 源码和 C2/C3a 停止契约；当前 context7 无可调用工具。

交给协调者：

- **D1**：按本报告/共享 schema 实施钥匙串与配置 UI、removed_account_id 清理；启动或后端重启在 SSE 连上后注入密码。不要把 test/configure 返回当 online，不在外部后端模式自动注入。
- **D2/E**：消费摘要 id、旧账号/世代 410、WebKit 安全与 ViewingContext read、两领域快照恢复、整批通知投递/抑制后 ack、read/deleted/reset 的系统目标清理。Email App 仍不能阅读，不勾选 App 项。
- **F**：真实 Seen 持久化、跨端未读/60 秒、合法测试新信来源、实际通知点击、断网/睡眠与长期 IDLE，仍按 A 的授权前提待验。这里的合成 wire/进程计时不能替代真实接入。
- **平台边界**：DNS 无句柄不能强制杀 Python 线程；30 秒 HTTP 超时后 cleanup 至多再约 1.5 秒，等待 closed 前不再建新网络 owner。客户端断开/超时不撤销已经提交的配置或 wire STORE，先取状态再重试。

未发现新增影响已交付 App 的未解决缺陷；以上为既定阶段或明确平台限制，known-issues/next-up 既有条目保持。协调文档由 coordinator 签收维护，本执行者未修改。

## 资源清理

pytest/子进程、loopback HTTP/SSE/IMAP、network/render/probe owners、SQLite 和独立入口冒烟均清理。`evidence-audit.json` 确认本任务残留进程为 []，带本任务前缀的临时停止目录为 []；fixture 验证正常 thread/peer/socket/future 全部收敛，DNS 子进程仅保留平台允许的限时退役并完成退出。独立安装 venv 已删除，tmp 仅保留合成证据/脚本/wheel，不含真实账号或凭证。未启动 App、浏览器、模拟器、caffeinate，没有自建 GUI 资源需要 mac-dev-cleanup，不清理其他会话/用户资源。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 完整阅读共同约束及 C3b brief；只读。
- [原邮件计划](../plans/2026-10-13-email-reader-plan.md) — 完整阅读，更新有证据的 C 检查项。
- [C1 交接](2026-10-13-email-foundation-c1.md)、[C2 交接](2026-10-13-email-imap-executor-c2.md)、[C3a 交接](2026-10-13-email-sync-c3a.md) — 完整阅读并接续真实生产模型、服务及停止限制。
- [邮件基础文档](../docs/email-foundation.md) — 更新当前 HTTP/SSE/进程边界与恢复行为。
