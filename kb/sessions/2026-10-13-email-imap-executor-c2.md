---
created: 2026-10-13
tags:
  - email
  - imap
  - python
  - phase-c2
---

# 邮件 C2：IMAP 适配器与可中断串行执行器

## 概要

当前 master 完成 C2：真实 IMAPClient 4.1.0 的 INBOX 异步适配器、专用 daemon 所有者、有界优先队列、可中断/续订 IDLE、TLS 验证、库分配和解析前的网络限额，以及 C1 MIME/HTML 工作线程入口。行为测试先写，所有样本为合成数据；后端最终全量结果与资源审计见下节。

只做 C2，未读取 env/凭证/真实缓存、连接真实账号、修改 App、接通业务同步/API/SSE、设置 mail feature、开始 C3、委派、修改协调文档、push 或发布。coordinator 的签收和下一阶段分派保持等待。

## 修改的文件

- `backend/src/feishu_lite/mail/imap.py`：异步目录、选择、UID 查询/分页、摘要、正文、已读及缓存净化入口。
- `backend/src/feishu_lite/mail/executor.py`：一连接一 daemon，串行/优先队列、取消、世代结果、断线观察、IDLE/DONE 时限和停止。
- `backend/src/feishu_lite/mail/transport.py`：集中封装 IMAPClient 4.1.0 与 Python 3.12 imaplib 扩展；提前发布 TCP/TLS socket、原始读取预算、半行保留、持续推送公平性及协议日志屏蔽。
- `backend/src/feishu_lite/mail/types.py`：ImapConfig/Identity/Result、SelectedMailbox、FetchedBody、独立 MailAuthenticationError；C1 模型/存储 schema 不变。
- `backend/tests/mail/{imap_server,stop_child,test_imap_executor,test_imap_shutdown_tls}.py`：真实库配合 asyncio IMAP/TLS 服务端、失败样本和完整 FastAPI lifespan 子进程退出。
- `AGENTS.md`、`backend/README.md`、[邮件基础文档](../docs/email-foundation.md)、[原计划](../plans/2026-10-13-email-reader-plan.md)：更新当前状态与独立 C2 证据子项，组合 C 项尚未完成。本报告随实现提交。

## 生产接口与 C3 接续

以下方法均返回 `ImapResult`，包含 `identity` 和 `value`，只有 stop 无返回值。构造不启动线程/联网；第一次异步工作才启动专用线程。配置只留内存，username/password 为 SecretStr，repr 和 model_dump 均排除；不能把整个配置当 API/status payload。

| 方法 | value / 契约 |
| --- | --- |
| `connect()` | CAPABILITY tuple；正常 TLS 校验证书与主机名；每实例只连一次，失败由 C3 决定新建实例 |
| `list_folders()` | 全部 MailFolder，中文/层级由真实库解码；Noselect 不可选择；INBOX 标识统一大写，name 保留 LIST 原值，其他 id 保留原值 |
| `select_inbox(readonly=False)` | SelectedMailbox：folder_id、UIDVALIDITY、UIDNEXT、FLAGS、PERMANENTFLAGS、readonly；SELECT 返回只读时库会抛 readonly，适配器随后 EXAMINE 取得元数据，不伪称可写 |
| `all_uids(folder='INBOX')` | 全箱 UID 倒序；没有排序扩展假设 |
| `unseen(folder='INBOX')` | 全箱未读 UID 升序，不能把 SELECT 的 UNSEEN 当未读数 |
| `new_uids(watermark, folder='INBOX')` | UID SEARCH UID n:*，严格过滤小于水位的尾 UID；2^32 水位直接返回空 |
| `existing_uids(cached, folder='INBOX')` | UID SEARCH 指定集合，交集升序；单次最多 100 UID，大缓存由 C3 分批 |
| `uid_page(before_uid=None, limit=100, folder='INBOX')` | 对 ALL UID 列表倒序切片；后续传 before_uid 与 limit=50，不做 UID 算术分页 |
| `summaries(uids, folder='INBOX')` | 最多 100 UID；按输入顺序返回 C1 MailSummary，仅 FLAGS/INTERNALDATE/RFC822.SIZE/BODYSTRUCTURE 与 FROM/TO/CC/SUBJECT/DATE/MESSAGE-ID 的 HEADER.FIELDS PEEK；收到时间为带时区 INTERNALDATE 的 Unix 秒 |
| `body(key, part)` | FetchedBody(raw, body)：part 必须来自 C1 selected.body/缓存摘要的 body_part，数字 section、安全文本媒体类型、非 attachment；只取 BODY.PEEK[section]，无 STORE 副作用；工作线程 decode + render，raw 供 Store，body 供展示 |
| `mark_seen(key)` | None；高优先级，校验世代、只读/永久 flags、UID 存在；+FLAGS.SILENT (Seen) 后单 UID FETCH FLAGS 再验证目标仍存在及 Seen 已返回，保留其他标志；C3 再做整箱 UNSEEN 对账 |
| `render_cached_body(raw)` | MailBody；同一专用线程净化，不把 Store 传入线程；未 connect 的实例也可执行，故不依赖网络就绪 |
| `stop()` | 撤销 pending，停止/关闭；通常完全结束所有者，DNS 无句柄超过 1.5 秒抛 stop_timeout，详见停止限制 |

内容方法在后端检查 INBOX 语义，不能仅靠 UI 禁用其他目录。INBOX 键大写避免服务端 LIST `inbox`、SELECT `INBOX` 与 C1 Store 分区不一致；真实库→Store 的合成往返已测。只有 identity.generation 表示 C3 指定的连接世代，UIDVALIDITY 是另外的邮件世代。

```python
from pydantic import SecretStr
from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.types import ImapConfig

# 在 C3 生命周期边界执行；此处是交接示例，不是已实现的同步服务。
io = ImapAdapter(ImapConfig(account_id=account_id, generation=generation,
                           username=SecretStr(address), password=SecretStr(password)))
await io.connect()
folders = await io.list_folders()
selected = await io.select_inbox()
inbox = next(folder for folder in folders.value if folder.id == 'INBOX' and folder.supported)
store.save_folders(account_id, folders.value)          # 事件循环线程
store.reset_folder(account_id, inbox, selected.value.uidvalidity, selected.value.uidnext)
uids = await io.uid_page(limit=100)
summaries = await io.summaries(uids.value)
if summaries.identity == active_identity:             # C3 还核对 UIDVALIDITY
    store.save_summaries(summaries.value)

raw = store.get_raw_body(key)                         # 事件循环 detach
display = await io.render_cached_body(raw)            # 工作线程净化
# 网络 miss: await io.body(key, store.get_summary(key).body_part)
# 比较身份/当前选择后才能写 cache/返回展示；只有独立显式 read 才调用 mark_seen。
await io.stop()                                      # 生命周期顶层处理安全错误
```

C3 在收到 LIST/SELECT 结果后、所有缓存写入和事件投递前核对 active identity 与 UIDVALIDITY，账号移除/更换先 stop，再删缓存。每次重连建立新的 adapter 和 generation，账号 id/原水位不因此重置。不跨线程读写 Store 或 emit SSE。

`reconcile_needed` 是 asyncio.Event，推送只合并成需对账信号，不解析序号；C3 先 clear 再执行对账，期间新推送会再次 set。`closed` 是清理完成事件，`failure` 是安全 MailError 或 None；C3 可 await closed 立即观察无人请求时 IDLE 断线。认证失败不自动重试。无 IDLE 时正常请求可用，60 秒检查/45 秒对账调度都属于 C3。

缓存展示不能依赖故障网络实例仍可用：退役实例拒绝后续工作。C3 可保留一个只调用 render_cached_body、从不 connect 的实例作为离线净化所有者（构造时两个 SecretStr 可为空，不需要读取钥匙串），并随账号生命周期 stop。不要为了缓存净化把 SQLite 放线程，也不要调用默认线程池承载永久任务。只有当前 C2 网络实例的 I/O/解析所有权已实现；具体离线服务组装留 C3。

## 错误、取消与线程契约

- `MailAuthenticationError` 是 MailError 的邮件专用子类，code=authentication_failed，与聊天 AuthExpired 无继承关系。调用方按安全 code 分类，不记录原 cause/traceback/响应；TLS 错误 code=tls_failed，普通断网 code=disconnected。
- 命令默认绝对时限 10 秒，DONE 独立默认 0.6 秒；不把普通 socket 超时当 DONE 时限。idle_done_timeout、command_timeout、malformed_response、网络限额错误使连接退役，C3 stop 后重连。停止后的请求为 executor_stopped；队列满为 queue_full。
- 请求级错误包括 unsupported_folder、mailbox_not_selected、invalid_uid、invalid_batch、invalid_page_size、stale_message、unsupported_body、mailbox_readonly、command_rejected、message_missing、seen_not_persisted，以及完整读取后的正文解码/大小错误。安全继续的请求失败不关闭连接。
- 摘要在完整库解析后逐封处理；结构/编码/缺字段/日期错误返回带 error 的占位，部分 UID 消失不丢掉其他记录。所有请求 UID 都无响应时抛 message_missing。wire framing 或库级 FETCH parser 错误无法安全保留批次时退役，不能假造成功；C3 可重连后按 UID 缩小批次隔离。
- 队列默认 64 项（不含正在 wire 上的工作），取消项回收容量。正文、净化、STORE 优先于待执行后台查询/分页；同优先级 FIFO，不抢占已发出的命令。取消排队工作不发命令；取消正在 wire 的工作只丢弃结果，等待其有限 I/O 结束。已发送 STORE 无法撤销。
- 结果包含 account_id、generation、独立 connection_id。所有 asyncio future/event 只在事件循环访问，线程通过 call_soon_threadsafe 交付；停止/取消后的迟到结果不交付，已关闭的循环不阻止所有者清理。

## 网络限额与库扩展

使用库的 IDLE/idle_check/idle_done，没有自行实现 IDLE 协议。默认 idle_poll=0.05 秒，续订 28 分钟，参数禁止超过 29 分钟。持续推送时每次库轮询也有绝对时间预算，半行保留至下轮/DONE，不用非阻塞 readline 把半行当完整响应。

BoundedIMAP4 在 lib 创建 literal 前拒绝宣告大小：整个命令响应 8 MiB、头部 literal 256 KiB、正文 literal 2 MiB；实际字节同样计数，recv 每块最多 64 KiB。FETCH 行在递归库解析前扫描引号外括号深度/原子预算（默认 63 层/12800 原子），之后 C1 再执行 20 MIME 层/200 部分/正文解码上限。网络超限保留未读 wire，必须退役连接，不能直接继续 FETCH；C1 完整数据的单封错误可以占位继续。

仅本地合成测试可显式传 `_plaintext_loopback=True`，且必须 loopback IP；生产默认 TLS，拒绝未校验证书/主机名的 context。本地临时证书验证实际 TLS 成功、未知 CA 失败及信任 CA 但主机名不匹配失败。不开全局协议 debug；禁用 imaplib 输出及原始命令/响应日志 ring，再对本执行器线程过滤库 login/_raw_command 日志。过滤器不屏蔽其他 IMAPClient 使用者或应用日志。

提前发布 TCP socket、TLS 握手前发布 SSLSocket，以便事件循环 shutdown；正常 socket 操作仍只属于工作线程。shutdown 是明确的 IMAPClient public socket “仅轮询”契约扩展。集中封装 `_create_IMAP4` 与 imaplib read/readline/send 的版本相关行为；升级 IMAPClient 或 Python 必须重跑这些真实库测试。已检查安装包源码，并用 firecrawl-scrape 读取 [IMAPClient 4.1.0 官方 API](https://imapclient.readthedocs.io/en/4.1.0/api.html)；context7 本会话无可调用工具。快照只在 tmp，不新增下载文档到 kb/refs。

## 停止与计时证据

stop 立即撤销 pending，正常 IDLE 给 DONE/LOGOUT 0.15 秒机会，再 shutdown 打断阻塞，由所有者关 file/socket、清队列；无默认线程池，没有无限 join。正常清理事件 closed 在所有者完成后交付。故障场景和本地服务端均明确清理，不仅依赖 daemon。

例外是系统 getaddrinfo 尚未返回、没有 socket：Python 没有可移植的线程 DNS 取消机制。stop 在 1.5 秒期限返回 stop_timeout，撤销所有 future，但 daemon 可能暂存到 DNS 返回；返回后检查停止标志，绝不创建迟到 socket。测试既覆盖完整子进程限时退出，也覆盖 DNS 恢复后线程正常结束、无 socket/命令，以及循环已关闭时仍清理。C3 的 lifespan/账号移除边界须处理这一明确错误，不能等待默认线程池或无限等 DNS；真实账号/正式缓存没有被测试触及。

`tmp/2026-10-13-email-imap-executor-c2/measure.py` 用 uv 调用生产行为测试三轮，36 次计时均小于 2 秒；JSON 保存全部测量，下面是三轮最大值。请求起点是正文请求入队前的 monotonic，终点是 asyncio 服务端实际读到 UID FETCH；服务端 DONE tagged 确认故意延迟 60ms，检测确认前提前发命令。停止起点是父进程发送 STOP，终点是包含 FastAPI lifespan、实际 adapter、asyncio peer 和任务清理的整个测试子进程退出，不含解释器启动时间。

| 场景 | 最大秒数 |
| --- | ---: |
| 静默 IDLE → 正文 FETCH | 0.062566 |
| EXISTS/EXPUNGE/FETCH 推送 → 正文 FETCH | 0.062537 |
| 持续推送 → 正文 FETCH | 0.063666 |
| IDLE 半行、DONE 后补全 → 正文 FETCH | 0.062487 |
| 正常 IDLE 中完整进程停止 | 0.135485 |
| DONE 无确认中停止 | 0.182678 |
| FETCH 无返回中停止 | 0.032054 |
| FETCH 半行中停止 | 0.031438 |
| greeting 阻塞中停止 | 0.030639 |
| 本地 TLS 握手无回应中停止 | 0.033846 |
| DNS 无句柄中停止 | 1.524750 |
| TCP connect 受控阻塞 syscall 样本中停止 | 0.042622 |

TCP connect 卡住使用仅子进程中的可控 socket 子类，验证提前发布与 shutdown/清理路径；不是外网 SYN 黑洞实测。TLS/greeting/IDLE/DONE/FETCH 为真实 socket/库与本地服务端故障。DNS 延迟为受控 getaddrinfo 样本，不声称真实系统 resolver 立即可取消。真实飞书的网络速度、长期 IDLE 时限、Seen 持久化、新信/跨端/睡眠唤醒仍待 F 授权验证；A 的真实只读证据保持原边界。

## 行为测试与红绿证据

证据目录 `tmp/2026-10-13-email-imap-executor-c2/`，合成数据，无截图。执行 `cd backend && uv run pytest`。最终全量结果、JUnit 与资源审计写在此目录；复查若发现新问题，先补失败测试再修改。

最终 CPython 3.12.12 / IMAPClient 4.1.0：**后端全量 179 项通过，16.22 秒**（56 项 C2 + 84 项 C1 + 39 项既有回归）。`git diff --check` 通过；未运行 formatter/style linter、App 构建或 UI 验收。`evidence-audit.json` 保存测试/JUnit、36 次计时、文档链接与任务进程检查，以及日志 SHA256。

| 日志 | 红/绿证据 |
| --- | --- |
| tests-red.log | 首批测试先写，生产模块未实现时导入红灯 |
| tests-first-run.log / tests-first-green.log | 首轮真实库运行；修正测试预期以包含 Seen 存在查询，以及 peer EOF 的异步传播，不将夹具时序误称产品 bug |
| tests-logging-red.log | 成功认证仍有库用户名日志，运行期失败；随后加所有者线程过滤 |
| tests-hardening-red.log | 正常 IDLE 续订后停止没有 LOGOUT，运行期失败；随后给短期正常退出机会 |
| tests-seen-red.log | 3 项失败：STORE OK 但无标志/UID 消失、Seen 大小写；补验证与标准化 |
| tests-seen-green.log | 中间检查暴露 SELECT 的 readonly 异常，随后 EXAMINE 降为只读；旧正文断言也调整以包含新增单 UID FLAGS 验证 |
| tests-connect-red.log / tests-connect-green.log | 首 DNS 地址失败后不尝试后续地址，先红后修，TLS/进程测试绿 |
| tests-partial-red.log | 部分 FETCH 缺头部/UID 丢掉整批，2 项红灯；随后逐封占位 |
| tests-inbox-red.log | LIST 小写 INBOX 与 C1 cache 键不一致，先红后统一标识 |
| tests-loop-close-red.log | DNS 迟到时 closed loop 阻止清理；随后在跨线程交付边界处理循环关闭 |
| tests-log-buffer-red.log | debug=0 仍保存原始协议 ring；随后禁用 ring |
| tests-idle-close-red.log | 未提供无人请求断线观察入口；随后增加 closed/failure |
| tests-full-first.log | 中间全量 175 项通过 |
| tests-final.log / tests-final.xml | 最终全量结果，覆盖 C1 与全部既有聊天回归 |
| timing-{1,2,3}.log / .xml、timing-results.json | 三轮 36 个 wire/完整进程计时全部通过 |

服务端支持 CAPABILITY、LOGIN、LIST、SELECT/EXAMINE、UID SEARCH/FETCH/STORE、IDLE/DONE、LOGOUT，覆盖推送/持续推送、DONE 无确认、半行/半开、缺失 FETCH、断线、单封畸形/缺字段、超大宣告 literal/响应行/复杂结构、认证/STORE 拒绝、只读及删除竞态。额外验证 TLS、取消/优先队列/容量、世代隔离、无默认线程池、所有者净化、IDLE 续订、无人请求的断线事件、真实库→C1 Store。

## 注意事项、自主决策与遗留问题

普通技术选择均在 C2 内完成：轮询缩短为 50ms、独立 DONE 600ms、停止 join 1.5s、INBOX 键统一、STORE 后校验单 UID flags、closed/failure 和 render-only 能力。未扩大产品范围，不实施 C3 同步策略。网络超限/库 parser 错误选择退役而非尝试跳过不可信 wire，是避免错配响应的必要边界。

交给 coordinator 的事项：

- C3 必须接续 stop_timeout、closed/failure、结果身份/UIDVALIDITY 检查、认证不重试、网络重连退避与离线净化。同步水位/通知/API/SSE 未交付，不勾选组合 C 检查项。
- DNS 无句柄及 TCP 阻塞 syscall 的证据范围如上；不存在即时杀 Python 线程的承诺。真实断网/唤醒仍属 F，不能用本地计时代替。
- A/F 尚缺指定可修改测试邮件和发件来源；本任务不索取或使用账号，不补真实 Seen/跨端/新信/长期 IDLE 验证。

没有新增影响当前已交付 App 的确认缺陷；上述为协议/平台限制和既定后续阶段，`kb/known-issues.md` 与 next-up 的既有内容未修改。

## 资源清理

所有 pytest/计时进程已结束；本地 peer fixture 关闭 listener、writers 及 tasks，owner 关闭 socket/file，pending future 清空。DNS 恢复场景验证 daemon 结束；完整子进程 DNS 卡住场景退出时没有任何 socket。最终审计只检查本任务，不操作用户 App、正式数据或其他任务进程。未启动浏览器、模拟器、App 或 caffeinate，故没有对应自建资源需要 mac-dev-cleanup，不运行广泛清理影响其他会话。保留 tmp 红绿日志/计时/官方 API 快照，无截图。

收尾时协调文档有 coordinator 持有的 C3a brief 未提交改动，用户明确要求保留；本执行者未清理、暂存或提交它。审计按 C2 受控文件与提交范围验证：C2 文件没有剩余改动，本提交没有触及协调文档/App/known-issues/next-up；checkout 的协调文档差异保留给 coordinator，不把全目录干净作为收尾前提。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 完整读取当前 C2 brief 与共同约定，未修改。
- [原邮件计划](../plans/2026-10-13-email-reader-plan.md) — 实施依据，增加独立 C2 证据子项。
- [A 探路笔记](../notes/2026-10-13-email-imap-probe.md)、[A 实际报告](2026-10-13-email-imap-phase-a.md) — IMAPClient 选型、真实与隔离边界。
- [C1 实际报告](2026-10-13-email-foundation-c1.md) — 共享类型、BodyData/section、线程与存储交接，保持这些契约。
- [邮件缓存与安全正文](../docs/email-foundation.md) — 更新适配器状态、INBOX 身份与通信/停止行为。
