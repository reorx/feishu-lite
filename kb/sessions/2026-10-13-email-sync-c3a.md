---
created: 2026-10-13
tags:
  - email
  - python
  - sync
  - phase-c3a
---

# 邮件 C3a：独立同步、账号生命周期和提醒交接

## 概要

在当前 master 完成独立 MailService，复用真实 C1 MailStore 和 C2 ImapAdapter：账号配置/凭证注入、INBOX 初次与增量同步、全箱未读、历史分页、正文缓存与离线净化、显式已读、持久 pending/ack 和领域事件。先写失败行为测试，复查发现的竞态也先复现再修复。最终 **后端全量 221 项通过，21.18 秒**（C3a 新增 42 项，前序 179 项），git diff --check 通过。

本次未新增 HTTP/SSE 路由、改现有进程生命周期或聊天 Service、修改 App、宣告 mail feature、读取 env/真实数据、访问真实账号、开始 C3b、委派、push 或发布。协调文档只读；coordinator 保持等待并根据本报告签收。

## 修改的文件

- `backend/src/feishu_lite/mail/service.py`：独立业务服务与生命周期，构造/导入不联网。
- `backend/src/feishu_lite/mail/types.py`：MailStatus、MailEvent、MailNotification、MailAccountChange、MailConnectionTest，均为共享 Pydantic 模型。
- `backend/src/feishu_lite/mail/store.py`：仅增加 accounts 和 has_folder 两个读取入口供恢复配置/判断尚未 SELECT；schema、既有原子写入与 C1/C2 契约保持。
- `backend/tests/mail/fake_imap.py`、`test_service.py`：真实 SQLite + 可控 C2 契约 fake，38 个行为场景。
- `backend/tests/mail/service_stop_child.py`、`test_service_shutdown.py`：真实 C2 + 独立 Store + 完整 asyncio 进程停止，4 个场景。
- `AGENTS.md`、`backend/README.md`、邮件基础文档、原计划：更新当前实现/接续入口及有证据的独立 C3a 子项；本报告同次提交。

没有依赖、锁文件或 IMAPClient/transport/executor 改动。未运行 formatter/style linter、App 构建或 UI 验收。

## 生产方法与数据契约

服务在 Store 所属事件循环中创建/使用。调用方负责 Store 的创建和关闭，停止时先 await service.stop，再 close Store；不能把 Store 传给工作线程。默认 factory 为 ImapAdapter；测试可注入 adapter_factory、Unix 秒 clock 和同步 emit 回调。emit 接收 MailEvent，必须非阻塞且不抛异常，后续 SSE 桥负责有界队列满时的处理；没有订阅者可以直接丢弃事件，pending 已先持久化。

| 方法 | 返回与行为 |
| --- | --- |
| `await start()` | 从 mail.db 恢复唯一账号；未配置为 unconfigured，已配置为 credential_missing；不连网络，不读取钥匙串。幂等，停止后不可重启同一对象。多个缓存账号为 account_config_invalid。 |
| `status()` | MailStatus 快照，包含待提醒；同步读取，只读 Store。停止期间可用作诊断。 |
| `await configure(address, SecretStr)` | MailAccountChange(account, removed_account_id)。新地址生成 UUID；先撤销/stop，再删除旧缓存并保存新配置，启动一个后台循环。相同地址沿用账号 id 并按注入规则处理。返回不意味着 IMAP 已上线。 |
| `await inject_credential(account_id, SecretStr)` | id 不匹配为 account_mismatch；同密码重复注入不换连接、不清缓存/水位。同一个已被拒绝的密码也不重试；新密码重启同步。后端重建后的第一次注入恢复原账号。 |
| `await remove_account()` | MailAccountChange(removed_account_id=旧 id)，供 App 清理对应钥匙串/通知。只清邮箱数据，状态/未读归零；重复移除可用。 |
| `await test_connection(address, SecretStr)` | MailConnectionTest(writable, supports_idle)。临时 UUID/连接，不写 Store；connect/LIST/SELECT 后必定 stop。一次最多一个试连，第二个为 connection_test_busy；服务 stop 可打断试连，不等试连生命周期锁。 |
| `await refresh(reconnect=False, wait=True)` | 与进行中的轮次合并；默认等待轮次成功/安全错误。reconnect 丢弃旧网络实例，轮次中收到该请求时完成新连接对账才返回。wait=False 仅触发；后台消化异常，结果从状态/事件读取。 |
| `folders()` | 完整缓存 LIST 目录，保留中文/层级/Noselect；内容接口依旧只允许 INBOX。 |
| `await messages(folder='INBOX', cursor=None)` | MailPage。在线按服务端全部 UID 倒序切片，初始 100/后续 50；缺失摘要按最多 100 FETCH 回填。正文不参与，回填不推进同步水位/不提醒。离线只分页已缓存摘要。 |
| `await body(message_id)` | MailBody，没有已读副作用。命中先 get_raw_body detach，再交独立 render-only owner 净化；它没有用户名/密码，也不 connect。miss 调 C2 body(key, body_part)，仅保存 raw、返回净化 body。账号/连接/UIDVALIDITY/删除在等待后再校验。 |
| `await read(message_id)` | 新变已读的 id 列表，供清理通知。只有 C2 STORE 核实成功、整箱 UNSEEN 与目标存在再次验证后才更新缓存；并发 read 串行，防止旧快照恢复另一封未读。已读目标幂等返回 []。离线为 offline，不记录待写队列。 |
| `await ack(account_id, uidvalidity, batch_id)` | 确认整批，Store 处理乱序/幂等和连续通知水位。过期世代为 stale_message；没有配置/错账号拒绝。 |
| `await stop()` | 幂等撤销所有轮次和迟到请求，同时停止网络、render-only、试连与正在退役的所有者；只释放服务资源，不清持久账号/缓存，不关闭调用方 Store。 |

MailStatus 字段：`mail_account_id`、`address`、`state`、`generation`、`uidvalidity`、`last_sync_at`、`unread_count`、`unread_stale`、`pending`、安全 `error`。last_sync_at 来自最后成功的全箱 UNSEEN 快照检查时间，包括显式 read 后的检查。offline/auth_failed/credential_missing 保留缓存计数并标记过期。连接 generation 在本服务对象内递增；重启后重新计数，不能当作跨进程持久同步水位。

MailNotification 字段：`id`（批次）、`account_id`、`folder_id`、`uidvalidity`、`mode`（individual/summary）、`items`（MailSummary）。individual 的每一项用稳定 MailKey.id 作为系统通知 identifier/单封目标；整批所有项已投递或按可见性规则抑制后 ack 批次。summary 使用稳定 batch id 作为 identifier，点击回 INBOX。按账号加 mail 命名空间，不能与聊天通知共用清理范围。

MailAccountChange 的 removed_account_id 必须被 D1/E 消费：更换和移除都要清旧账号钥匙串、已递送通知和选择。后端不操作钥匙串或系统通知。

## 领域事件与 C3b 接线示例

MailEvent 顶层包含 `type`、`account_id`、`generation`、`folder_id`、`uidvalidity`，以及按事件使用的 payload；无密码/RawBody/原库异常。缓存/事件全部在事件循环线程，工作线程只交付 C2 数据。

| type | payload / 消费方式 |
| --- | --- |
| mail.status | status=MailStatus，配置/连接/认证/离线/上线/ack/read 后刷新快照。 |
| mail.updated | read_ids、deleted_ids、reset；列表/flags/删除变化后重新读取。reset=True 表示旧 UIDVALIDITY 目标全部失效，先清该账号旧邮件目标，再读取新世代。read 期间发现删除也发 deleted_ids 后返回 message_missing。 |
| mail.arrived | notification=MailNotification；新批次先持久化，再仅发一次该事件。发事件不 ack；重连不重发旧事件，消费者从 status.pending 补处理。 |

下面仅是给下一阶段的调用示例，没有实际修改 api/main/lifespan：

```python
from pathlib import Path
from pydantic import SecretStr
from feishu_lite.mail.service import MailService
from feishu_lite.mail.store import MailStore

store = MailStore(Path(data_dir) / 'mail.db')  # 在所属事件循环构造
mail = MailService(store, emit=enqueue_mail_event)
await mail.start()
# 已配置账号: App 本次只注入密码，不重置基线。
await mail.inject_credential(mail.status().mail_account_id, SecretStr(password))
await mail.refresh()                         # 等待成功或安全 MailError
snapshot = mail.status().model_dump(mode='json')
page = await mail.messages()
body = await mail.body(page.items[0].key.id)   # 不会 Seen
# 仅在 App 通过 ViewingContext 的可见性判断后另行调用 read。
await mail.stop()
store.close()
```

C3b 负责 HTTP 鉴权、422 去除 input、请求 SecretStr、mail 域错误映射与 SSE 桥、feature 声明、独立 lifespan 启停和队列背压。API 只序列化共享模型；不能序列化 service/config/RawBody、回显请求体或记录异常 cause/traceback。MailAuthenticationError/MailError.code=authentication_failed 不进入聊天 AuthExpired。App 重新连 SSE 后读取 status.pending，不依赖 SSE 历史回放。

## 持久化与同步策略

复用 mail.db accounts、folders、summaries/bodies、unseen、notification_batches/items，不增加 schema 或另外的配置文件。只新增 Store.accounts/has_folder 读取方法，C1/C2 所有既有接口保持。

- 首次 SELECT 的 UIDNEXT 原子建立原基线；checked_at=None 表示尚未完成第一次对账，断线/服务重建后补抓最近 100 条历史摘要。后续 SELECT 同 UIDVALIDITY 保留水位；变世代清旧正文/游标/pending，并静默重建。
- 默认独立 45 秒对账；无 IDLE 也因此在正常网络下最多约 45 秒开始新信检查，不另建 60 秒循环。周期时间加网络执行时间不作为真实 60 秒验收证据。IDLE/closed、手动/强制刷新共用一个 runner，分页用同步锁保护连接更换，body/Seen 仍使用 C2 高优先队列。
- 每轮先全箱 UNSEEN、新 UID 过滤，然后摘要、分批缓存存在检查。新摘要或显式 read 插入轮次时，补查 UNSEEN，避免旧快照误清 pending/恢复未读。新增提醒摘要 + sync_next + pending 调 C1 原子 commit_arrivals；静默区间 advance_sync 不越过旧未确认批次。badge 完全来自全箱 unseen，不从分页推算。
- 新未读超过 3 封，或任何有已知 INTERNALDATE 的合格邮件比发现时早严格超过 600 秒，创建 summary；其余 individual。模式编码在稳定批次 id 的前缀，重启/成员被读删后保持。收件时间未知的错误占位为 0，不凭此冒充补收年龄；仍保留新未读提醒目标，App 使用错误/空字段回退文案。
- 已读/删除剔除 pending 成员，空批次当作已确认推进；乱序 ack 不跨越旧 pending。mode/id 不会因重连或 status 读取改变。没有订阅者也能在重启后恢复，事件本身不是进度确认。
- 网络退避默认 1/2/5/10/30/60 秒（上限 60 秒），手动刷新可提前唤起；认证失败结束 runner，等待不同凭证。同密码注入不会制造认证重试。
- 生命周期 epoch、C2 account/generation/connection_id、邮件 UIDVALIDITY 都在异步结果后校验。移除/切换先 fence + stop，迟到 body/Seen/初始 SELECT 无法写回旧账号。发送到 wire 的 STORE 仍不可撤销，服务只拒绝迟到的本地成功结果。

## 错误隔离与停止

只对库级 parser/响应结构限额错误缩批重连；网络/认证失败不被误当作单封错误。每个服务轮次或用户分页最多 8 次隔离重连；单 UID 错误保存安全占位，预算耗尽后的未尝试摘要为 summary_unavailable，用户再次加载该页可有限重试。正常周期不反复 FETCH 已确认坏封，后续正常 UID 可以继续同步。最后一封坏邮件退役连接后也重新取得干净连接完成对账，最多另有一次收尾连接。

新单封正文错误直接返回安全 MailError；已有工作线程净化入口不因故障网络实例退休而失效。错误占位不下载附件，也不伪造正文。错误/超限样本为合成数据。

C2 stop_timeout 在生命周期顶层被捕获；立即丢弃结果，保留 retired owner，直到 closed 才允许新建网络/试连实例。不会周期性创建新的 DNS daemon。所有者 stop 在 await 前登记，使用受保护的专门任务，runner 被取消仍不会丢掉正在退役的 owner。网络、render-only 和试连并行停止，避免多个 1.5 秒等待叠加。

服务 stop 正常返回后可能仍有 C2 明确的无句柄 DNS daemon 尚未结束；它不能建迟到 socket、不能交付结果，进程不会等默认线程池。stop_timeout 可从诊断 error/retired 状态观察；运行中的服务显示 offline/stop_timeout，并等待 closed。平台 DNS 限制保留，不声称强制杀 Python 线程。

完整子进程使用生产 MailService + 真实 ImapAdapter/IMAPClient + 本地脚本服务端 + 临时 SQLite；计时从父进程发送 STOP 到子进程全部退出，不含解释器启动。最后全量 JUnit 的实际值：

| 场景 | 秒 |
| --- | ---: |
| IDLE + render-only 两所有者停止 | 0.131168 |
| 正文 FETCH 无响应 | 0.024929 |
| greeting 阻塞 | 0.025198 |
| DNS 无句柄，有限退役/完整进程退出 | 1.524385 |

四项均 <2 秒。C2 的 DONE、TLS、半行等原有专项随全量回归通过，本次不重新访问真实飞书探路。DNS 为受控系统 getaddrinfo 阻塞，其他为本地真实 socket/库；均不代表真实断网或睡眠已验收。

## 红绿测试证据

证据目录 `tmp/2026-10-13-email-sync-c3a/`，全为合成数据，无截图。命令在 backend 执行：`uv run pytest`；最终保存 JUnit 时加 `-o junit_family=legacy`，避免 pytest record_property 与 xunit2 的格式警告。

| 日志 | 证据 |
| --- | --- |
| tests-red.log | 首批行为测试先写，缺少 service 模块的导入期红灯。 |
| tests-first-run.log | 首批 18 项通过。 |
| tests-races-red.log / tests-races-green.log | 新信晚于 UNSEEN 被误已读、末尾坏封导致 service_failed 两项运行期红灯；修正后 24 项通过。 |
| tests-lifecycle-red.log / tests-lifecycle-green.log | 同一个拒绝密码仍触发重试、试连持有锁阻挡 stop 两项红灯；改为相同密码幂等/试连单独跟踪。 |
| tests-retirement-red.log / tests-retirement-green.log | 退役中取消 runner 会提前返回并漏 owner 的复现；登记并保护 stop 任务后 35 项通过（含 4 子进程）。 |
| tests-recovery-red.log / tests-recovery-green.log | 初始导入中断后不补摘要、read 中删除不发清理目标两项红灯；修正后 39 项通过。 |
| tests-concurrency-red.log | 并发 read 恢复未读、新封 Seen→未读丢 pending、预算未尝试的好封永久占位三项红灯。 |
| tests-placeholder-notifications-red.log | 补充坏封/预算占位仍须保留新未读提醒目标；运行期红灯，同时覆盖上述竞态。 |
| tests-concurrency-green.log / tests-service.xml | 最终 C3a 42 项通过。 |
| tests-full.log / tests-full.xml | 最终后端全量 221 项通过，21.18 秒。 |
| audit_evidence.py / evidence-audit.json | uv 执行的日志 SHA256、4 个实际停止时限、任务子进程与受控范围/文档链接审计。 |

测试覆盖首次静默、初始化间隙/中断恢复、稀疏分页/完整目录、整箱计数、n:* 去重、150+ 增量/100 UID 分批、稳定阈值与重启 pending、乱序 ack、跨端 flags/删除、UIDVALIDITY、网络/认证/幂等凭证、迟到 body/Seen/初始结果、离线正文/列表、无 IDLE 周期、IDLE/closed、推送洪水合并、刷新调用者取消、显式 read 并发、单封与预算隔离和完整退出。Store 为真实SQLite，fake 不造第二套缓存；独立子进程进一步验证真实库和工作线程/Store 分工。

## 注意事项与遗留问题

普通实现选择：账号配置直接复用 accounts 表；最后成功全箱快照时间复用 checked_at；一个 45 秒循环承担无 IDLE 新信检查；逐封通知按整批 ack；模式前缀持久化；每轮 8 次解析隔离预算和用户页重试；错误占位也保留提醒目标。这些在 C3a 范围内，无外部行为权限扩展。

- **C3b 尚未实现**：HTTP/SSE/lifespan、鉴权/422/feature/error 映射、客户端断连/backpressure 的端到端测试由下一任务完成，不能因服务测试通过勾选组合 API 项。
- **D/E 尚未实现**：钥匙串、配置/阅读 UI、ViewingContext 已读、通知投递/抑制/ack、稳定 identifier 和目标失效消费；本次提供的数据不等于实际系统通知已经投递。
- **F 真实待验**：真实 Seen 持久化、跨端 FLAGS、通知/新信来源、睡眠唤醒及 60 秒目标仍按 A 与原计划的授权前提等待；未取用真实凭证或邮件。
- **平台与有意边界**：DNS 无句柄不能即时取消线程；离线页仅缓存；UIDVALIDITY 在 SELECT 观察；持续推送/命令时长会增加周期执行时间；永久畸形摘要保持占位，未尝试好摘要可在页请求重试。没有创建无限重试/默认线程池。

没有新增影响当前已交付 App 的确认缺陷；known-issues/next-up 的既有条目保持，不把待交付 C3b/D/E 记成使用中的缺陷。原计划仅新增已验证的 C3a 子项，协调状态交给 coordinator。

## 资源清理

全量 pytest 与 4 个本任务子进程均已退出；测试 fixture 关闭 Store，fake/真实所有者 stop、pending future 清空、peer listener/writers/tasks 关闭。审计未发现 service_stop_child/stop_child 残留。DNS 子进程明确限时退出，无迟到 socket；同一服务 fake 验证 closed 前不新增 owner。

未启动 App、浏览器、模拟器、caffeinate 或真实 IMAP 连接，没有需要 mac-dev-cleanup 的自建 GUI 资源，不运行广泛清理影响用户或其他会话。保留 tmp 红绿日志、JUnit、可复用 audit 脚本，无截图。提交不含 tmp、凭证、真实样本或协调文档；收尾核对工作区和提交范围。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 完整读取共同约定和当前 C3a，未修改。
- [原邮件计划](../plans/2026-10-13-email-reader-plan.md) — 完整读取并增加有证据的 C3a 独立子项。
- [A IMAP 探路](../notes/2026-10-13-email-imap-probe.md) — 读取真实/隔离边界，不重新探路。
- [C1 实际接口](2026-10-13-email-foundation-c1.md) — 真实 Store、原子 pending/ack、线程契约。
- [C2 实际接口](2026-10-13-email-imap-executor-c2.md) — identity、closed/failure、stop_timeout 和 render-only 契约。
- [邮件基础文档](../docs/email-foundation.md) — 同次更新当前账号、同步、缓存和正文行为。
