---
created: 2026-10-13
tags:
  - email
  - coordination
---

# 邮箱阅读器串行执行与验收交接

## PRD

执行已确认的 [邮件阅读器计划](2026-10-13-email-reader-plan.md)，不改变其产品范围。用户要求主会话仅协调和评审结果，开发、探路与实机验收由 Herdr 新 tab 中的 Codex 执行。逐任务推进，最终由协调者汇总独立验收结果。

## Tech Design

### 执行约定

- 本文由 coordinator 编写。工作目录 `/Users/reorx/Code/feishu-lite`，当前分支 `master`，不新建分支或 worktree，不 push、不发布。
- 同时最多一个执行者修改本 checkout。执行者只暂存自己的改动，实现与相关文档一并提交。
- 执行者先读根 AGENTS.md、原计划全文、适用技能；改 App 前读 mac/AGENTS.md。数据/逻辑先写失败行为测试，修 bug 先复现测试；不主动跑 formatter/style linter。
- 凭证已由用户提供在 `tmp/feishu-mail.env`。任何查看、读取、加载或操作必须先使用 envops 技能，禁止输出值、请求认证信息或真实邮件内容。不要将凭证复制到版本控制或报告。
- 用户仅授权既有聊天测试群 litetest；尚未指定可修改的真实邮件或新邮件发件来源。真实邮箱默认 EXAMINE + PEEK，只读。不得自行发信、修改真实邮件 flags、故意用错密码反复尝试或压力测试连接数。
- 执行者完成后报告提交、测试证据、自主决策、待验证项、资源清理。每阶段留独立 kb session/研究笔记；原计划仅勾选有证据的项目。未验证不算通过。
- coordinator 维护本文的阶段状态与交接。各执行者不得自行启动下一阶段或委派其他开发；若需独立实机验收，先报告 coordinator 分派新 tab。
- 共享 AGENTS.md/README/known-issues 的必要更新，由当次唯一执行者随实现提交，coordinator 仅审阅；不修改无关既有条目。

### 阶段与关卡

| 阶段 | 工作边界 | 进入下一阶段的证据 |
| --- | --- | --- |
| A | IMAP 只读探路与 Python 3.12 库选型 | 脱敏能力报告、IDLE 中断实测、限制和待验证清单 |
| B | 双模块外壳、MessagesState、ViewingContext、路由与 badge 基础 | 行为测试和构建通过，聊天语义不变 |
| C1 | 邮件领域模型、mail.db、MIME/正文净化 | 存储隔离、UID 标识、分页、编码/安全样本测试 |
| C2 | IMAP 适配器与串行执行、可中断 IDLE | 真实库配合最小脚本化 IMAP 服务端；请求与停止时限证据 |
| C3a | 独立同步服务、账号生命周期、待提醒/ack 与离线读取 | fake 适配器覆盖原计划同步状态机，接续 C1/C2 实际契约 |
| C3b | API/SSE 与进程生命周期接线 | 鉴权、错误隔离、防泄漏、真实本机 API 的端到端测试 |
| D1 | MailState、配置 UI、钥匙串、重启注入 | 状态/注入测试、隔离与错误路径证据 |
| D2 | 文件夹/列表/正文、WebKit、可见性已读 | 安全展示与迟到请求测试、构建通过 |
| E | badge/通知/路由/唤醒集成 | 跨模块、重连去重、清理和账号移除测试 |
| F | 新 tab 独立整体验收与逐项返修 | 全套测试、隔离 UI 截图、授权范围内真实接入、回归和最终差距报告 |

顺序 A → B → C1 → C2 → C3a → C3b → D1 → D2 → E → F。C3 按可独立验证的服务层与 HTTP 集成拆为两次串行交付，产品范围不变。任务 brief 在派发前根据上阶段实际接口落地，不让执行者猜测尚未实现的依赖。A 中需指定测试邮件的验证可保留至 F，不阻塞隔离开发。

### 任务 A：IMAP 只读探路（已签收）

执行者：新 Herdr tab 的 Codex。先读 envops 与 kb 技能、原计划 §2/§4/§6A。仅执行此任务，不实施 B–F。

目标：用现有凭证确认飞书 IMAP 实际能力，比较并选定符合 Python 3.12 和 2 秒可中断 IDLE 要求的库，为后端开发提供证据。

完成条件：

- 在 `tmp/2026-10-13-email-imap/` 留可复用脚本，用 uv 执行；报告不含凭证、人名、邮箱地址、主题或正文。
- 检查 TLS、正常认证、CAPABILITY、ID 要求、LIST 中文/层级、EXAMINE INBOX、UIDVALIDITY/UIDNEXT、FLAGS/BODYSTRUCTURE/PEEK，按原计划记录支持与不支持的能力。
- Python 3.12 下实测候选库 IDLE 可中断性；服务端不支持 IDLE 时用隔离最小服务端验证，明确区分真实与模拟证据。记录选择理由、命令串行化与退出方案。
- 不为测锁号而制造错误密码，不为探最大连接数而增加负载；这些项目明确记录未测。长期 IDLE 断开时限不凭短时观察推断。
- 尚无指定测试邮件，不执行 SELECT/STORE 或发信。真实 Seen 持久化、跨端 flags、新信通知记录待验事项，不索取聊天中的密码。
- 停止本任务自建连接/进程，保留用户 App。保存脱敏研究笔记到 `kb/notes/2026-10-13-email-imap-probe.md`，提交相关文档；tmp 脚本不强制入库。
- 最终报告：提交 hash、探路结论、Python/库版本、计时结果、哪些为真实/隔离/未测、后续开发注意点。遇到无法认证，记录准确的脱敏原因并完成能做的隔离选型，不宣称接入通过。

### 任务 B：双模块外壳与聊天状态拆分（实现已交付）

执行者：新的 Herdr tab 中 Codex。先读原计划全文、`mac/AGENTS.md`、SwiftUI 与 impeccable 技能，以及阶段 A 笔记 `kb/notes/2026-10-13-email-imap-probe.md`。A 已提交 `3cbc23d`，选定 IMAPClient，但本任务不实现邮箱后端或访问真实邮箱。

目标：完成原计划 §6B，使 Messages/Email 在窗口中独立切换；保留现有聊天功能，为后续 MailState 集成提供明确接口。

完成条件与范围：

- 先写 FeishuChatCore 的失败行为测试：Email 下旧选中聊天不自动已读也不抑制通知、回 Messages 补已读、路由编码/解码与模块选择、两模块未读汇总及 0/99+、BackendStatus 对缺失 features 的兼容。
- 按原计划拆分 AppState/MessagesState，建立 ViewingContext，统一 badge 与类型化通知路由。避免只写纯函数测试而调用点仍沿用旧行为；报告说明接入位置。
- 实现固定窄导航与重建式模块工作区，当前模块持久化，保存聊天选择、草稿、列表/详情滚动锚点。Email 本阶段可以明确显示待接入占位；不得借此宣称邮箱阅读器完成。
- 聊天未登录只影响 Messages；Email 下不启动扫码。BackendClient 仅对 detail=logged_out 的 409 映射聊天登出，其他错误不能吞掉。
- 保持启动引导、隐藏会话、图片展示、聊天发送与通知现有行为；不做无关重构，不引入真实邮箱凭证。
- 执行 `cd mac && make test && make build`；适用的现有后端检查由有无变更决定，不主动跑 formatter/style linter。新功能逻辑先失败测试，修 bug 先复现。
- 本 tab 完成自动验证，不启动实机 UI 验收。用户要求验收也交新 tab，交给 coordinator 后安排独立 B 验收，重点检查草稿/滚动恢复及 Email 回车不发聊天。不得把 UI 项提前勾选。
- 更新相关 AGENTS.md/README 与原计划有证据的检查项；session 写 `kb/sessions/2026-10-13-email-shell-phase-b.md`，列出给 C/D 的实际接口、测试证据、未做 UI 验收项、自主决策和偏离。
- 提交实现和相关文档；只暂存自己的文件，不修改本文，不 push、不发布、不开始 C，不自行开其他 agent。报告 commit hash 与干净工作区状态。

### 任务 B 验收：独立隔离 UI 与聊天回归（核心行为已签收）

执行者：新 Herdr tab 中 Codex，当前 master。基线提交 `66312a9`。先完整阅读原计划 §6B/§7、B session `kb/sessions/2026-10-13-email-shell-phase-b.md` 的接口和验收交接、`mac/AGENTS.md`、`~/.claude/docs/DESKTOP_APP_TESTING.md`、适用技能。此 brief 由 coordinator 编写；用户授权逐阶段开发与独立验收，主会话不执行具体测试或代码。

目标：用独立证据判定 B 是否可签收。B 的 65 Core + 5 状态测试及构建已通过，不把它们当 UI 验收证据。当前 Email 仅占位，不要求未实现的邮件 UI。

执行与完成条件：

- 先运行 `agent-inspect-session.sh` 检查 context；本身是新 tab，若实机前超过 40%，报告 coordinator 换新验收 tab，不自行委派。GUI 前运行 wake-screen，必要时使用有限时长 caffeinate。
- 使用完全隔离的本地模拟后端和合成聊天、消息、图片、通知目标。不得读取/复制真实账号配置、凭证、工作邮件或真实聊天；本任务不需要 tmp/feishu-mail.env。操作任何 env 文件先使用 envops。
- 保护用户正在运行的 App 和正式 UserDefaults/数据/通知；先检查已有实例，禁止直接使用会杀旧实例的 make run。采用项目已有隔离验收方法，若需调整测试启动方式，用可撤销的测试配置，不修改生产签名/Bundle ID。记录采用的隔离方式。
- 检查 B session 的四组交接：草稿及列表/详情首可见行恢复；Email 打字/回车不发聊天；最小 800×460 与拖宽、0/99+ badge、模块标题、重启恢复 Email 无 QR；Email 下新消息保留未读、返回 Messages 补已读；隐藏、图片、发送/翻页、关窗常驻、重连等既有行为。无法模拟或无法操作的项目明确未验，不冒充通过。
- 用模拟后端的 read/send/QR 请求计数支撑截图，保存逐项预期、实际和证据。可以编写可复用验收脚本到 tmp；非平凡解释器逻辑先写脚本再执行。Python 用 uv。
- 用户已获知会打开测试窗口、可能显示测试通知或模拟登录页且无需扫码；若需要真实登录、真实邮件状态写入或新权限范围，先报告 coordinator，不自行扩大范围。
- 此任务是独立验收，不直接修复产品代码。发现缺陷先收集最小复现、截图、请求计数、影响和建议，完成不依赖该缺陷的检查后交 coordinator 派返修。测试工具可以修正，不能绕过产品缺陷让测试通过。
- 截图及日志归档 `tmp/2026-10-13-email-reader/b-acceptance/`，只含合成数据；截图按项目规则保留。测试结束停止自建后端、测试 App、保持唤醒任务；按需 `mac-dev-cleanup --only browser --min-age 2`，不得清理用户正常 App。
- 写 `kb/sessions/2026-10-13-email-shell-b-acceptance.md`，按通过/失败/未验逐项记录；复核 B known-issues，已确实验证的条目移除，实际影响使用的缺陷保留准确描述。只对有证据的原计划条目勾选。必要时更新受影响文档，与验收报告一起提交；不修改本文、不 push、不发布、不开始 C。
- 最终回报：commit、测试与截图路径、缺陷列表、资源清理结果、对 B 能否签收的结论、交给 coordinator 的事项。在自己的 tab 返回摘要，详细结果落盘。coordinator 保持等待并读取报告后再派下一项。

### 任务 C1：邮件领域模型、存储与 MIME 解析（已签收）

执行者：新的 Herdr tab 中 Codex，在当前 master 上工作。先读根 AGENTS.md、原计划全文（尤其 §4 存储、§5 MIME/分页、§6C/§6D HTML）、A 笔记、B 实现与独立验收 session；使用适用的 Python/kb 技能，不熟悉的库依项目约定查正式文档。本文为 coordinator 的拆分，不改变原计划范围；接口细节允许按实际代码选择并在交接中说明。

目标：建立后续 C2/C3 可直接调用、已有行为测试的邮件领域基础；本阶段不连接真实邮箱、不提供可用邮箱 UI，也不提前接通生命周期/API/SSE。

完成条件与范围：

- 先写失败行为测试，再实现 `backend/src/feishu_lite/mail/` 中模型、独立存储及 MIME/安全正文处理。复杂结构用 Pydantic，跨模块模型集中放 mail 的类型模块；复用项目既有合理惯例，不建立通用消息插件框架。
- 独立 `mail.db`，WAL/busy_timeout/PRAGMA user_version 迁移。账号/文件夹/UIDVALIDITY/UID 稳定键与 base64url 对外 id、严格解码校验；游标包含 UIDVALIDITY 与 UID。验证旧 cursor/世代不被错用、账号隔离、清理不碰 cache.db、持久化重开和迁移。数据库写入为事件循环线程使用设计，不在线程写 SQLite，不持有密码。
- 摘要与正文分开缓存，正文保存解码后的原文以便读取时重新净化；按 UID 倒序分页（初始 100、后续 50 的调用能力），不连续 UID 不漏不重；摘要读取不依赖正文。为 C3 的全箱未读快照、UID 水位、pending/ack 提供持久化结构与原子操作，先测存储行为，不把 IMAP 同步状态机塞进 Store。删除/账号移除/UIDVALIDITY 重建要能安全失效旧正文、游标与通知关联。
- 头部 RFC2047、未声明编码 UTF-8→GB18030、gb2312/gbk→gb18030；附件 RFC2231 与常见编码文件名；HTML/纯文本 alternative、related 根、跳过 attachment 与 message/rfc822 子树；附件仅元数据，不下载内容。为 C2 交接明确 BODYSTRUCTURE 输入形式与正文 section 选择接口，覆盖 IMAPClient 4.1.0 BodyData 实际表示或给出严格转换契约，避免后续重复解析。
- 对响应/正文大小、MIME 深度/部分数设置明确阈值与结构化错误，超限/畸形单封错误不崩溃整批。低层只抛明确错误，顶层边界负责捕获；不加泛化 catch 吞错误。
- 后端 HTML 净化作为独立可测试能力完成：按计划评估 nh3，禁止脚本、iframe、表单、自动跳转、事件 handler、CSS URL、远程/CID/本地资源等，保留安全可读文本与允许的 HTTP(S) 用户链接。WebKit 的网络/CSP/导航隔离由 D2 实施，此处不能宣称浏览器安全验收已完成。读取时净化，不把未经净化的 HTML 当最终可展示字段。
- 样本全部合成脱敏，覆盖编码、multipart、附件名、恶意 HTML、超限及存储重启。依赖用 uv add；可为正式解析需要引入阶段 A 选定的 IMAPClient，但不启动真实连接。保留固定 commit 的 larkx 依赖。
- 验证 `cd backend && uv run pytest` 全部通过；修改范围限邮件基础及必要依赖、测试和文档，不变更 App，不主动跑 formatter/style linter，不读取 env 或真实缓存。
- 更新必要 AGENTS.md/README 与原计划证据条目，session 写 `kb/sessions/2026-10-13-email-foundation-c1.md`：具体接口与调用示例、数据 schema/迁移、错误类别、限额、测试红绿证据、后续 C2/C3/D 的责任、偏离和待验。未交付功能不冒充已实现，已知缺陷按 kb 规则登记。
- 当前分支提交实现和相关文档，不修改本文，不 push、不发布、不开始 C2 或委派其他 agent；清理自建资源。最终在 tab 报告 commit、测试、交接文档、工作区状态。coordinator 等待收尾信号并核对报告后派下一阶段。

### 任务 C2：IMAP 适配器与可中断串行执行器（已签收）

执行者：新 Herdr tab 的 Codex，当前 master。必读原计划 §4 IMAP 执行模型、§5 同步/正文规则、§6C；A 探路笔记、C1 session `kb/sessions/2026-10-13-email-foundation-c1.md` 与邮件基础源码/测试、根 AGENTS.md。库已通过 uv 引入 IMAPClient 4.1.0，不重新选型。

目标：让 C3 通过清晰的异步适配器调用邮件 I/O；真实库运行在专用 daemon 线程，同一连接上的命令串行，正文/已读优先，IDLE 可中断且停止不拖住进程。只做适配器和测试，不接 API/同步调度/App，不连接真实账号。

完成条件：

- 先写行为测试，使用 asyncio TCP 最小脚本化 IMAP 服务端驱动真实 IMAPClient（不是只 mock 库方法）。支持 LOGIN、LIST、SELECT/EXAMINE、UID SEARCH/FETCH/STORE、IDLE/DONE、LOGOUT，覆盖延迟、断线、推送 EXPUNGE/EXISTS/FETCH、DONE 无确认、半行/半开响应、FETCH 无返回。可复用 A 的思路，但不能把 A 的临时测试当生产适配器验证。
- 正常连接校验证书和主机名，端口/TLS 配置不泄漏密码；任何 SecretStr/异常/日志不得输出凭证、原响应或邮件。认证异常独立于聊天 AuthExpired，认证失败与普通断网可区分。真实 TLS 行为 A 已有依据，本阶段用合成服务端和必要本地 TLS fixture 验证，不读 tmp/feishu-mail.env。
- 一条连接一个所有者 daemon 线程，不使用默认线程池承载永久 IMAP 任务；跨线程结果通过事件循环安全入口返回，工作线程不访问 MailStore/SQLite 或直接 emit SSE。提供账号/连接世代，停止或取消后迟到结果不得交付给新账号。排队请求有界、取消可收敛。
- 串行命令队列：等待 IDLE 时有请求先 DONE，收到 tagged 确认才发下一命令；正文/STORE 优先于待执行分页/对账（不要求抢占已在 wire 的单条命令）。无 IDLE 时有可用正常请求路径；推送仅视为需对账信号，不解释序号。续订不超过 29 分钟，45 秒对账调度由 C3 管理。
- 正常 IDLE 中的正文请求入队后 2 秒内开始 FETCH。DONE 无确认时在有限期限内断开并返回明确错误，不能并发发送 FETCH 或无限等普通 socket 超时。记录测试时限与计时起止，避免只测 mock 的瞬间完成。
- stop 在 IDLE、DONE、FETCH、建连/greeting/TLS 阻塞等阶段均在 2 秒内让完整服务测试子进程退出；必要时由事件循环对公开 socket shutdown，中断阻塞读，所有者清理。daemon 不能代替正常资源关闭：测试 socket、线程、pending future 和本地服务端清理；没有句柄时的建连限制须明确且有测试。
- LIST 返回全部目录，中文/层级/selectable 正确；收件箱识别按 INBOX 语义。内容读取仅 INBOX，后端限制不能只留 UI。SELECT 元数据包含 UIDVALIDITY、UIDNEXT、PERMANENTFLAGS/只读状态，不能把 UNSEEN 响应当未读数；提供全箱 unseen、UID 列表、新 UID 与缓存存在查询基础，不做每轮 FETCH 1:* FLAGS/STATUS selected mailbox。
- 摘要只取 FLAGS/INTERNALDATE/RFC822.SIZE/BODYSTRUCTURE/指定 HEADER.FIELDS PEEK，用 C1 解析生成共享模型。正文只按 C1 selected.body 数字 section 发 BODY.PEEK，不下载附件或整个 RFC822；STORE 用 +FLAGS.SILENT (\\Seen)，保留其他 flags，拒绝失败/只读时伪成功。适配器不因读取正文而 STORE。
- 在网络读取/库解析之前限制单次响应、literal、BODYSTRUCTURE 输入；C1 默认响应 8 MiB、头部 256 KiB、正文 2 MiB，不接受先分配巨大 literal 再检查。必要的库扩展集中、明确说明与测试，不手写 IDLE。遇到恶意/畸形单封可分类失败，不能卡死后续请求/聊天事件循环；脚本化服务端验证超限、断线、持续推送的公平性。
- C1 的 get_raw_body/render_body 分线程约定保持；提供工作线程解析/净化入口或清楚交接供 C3 使用，不能在事件循环执行大块 MIME/HTML 工作。正常库 I/O、解析所有权一致，避免不必要的新执行框架。
- 跑后端全量 `uv run pytest`；已有 C1/聊天行为不回退，不跑 formatter/style linter。限额/超时/资源清理等失败先复现再修。测试必须使用合成脱敏协议样本。
- session 写 `kb/sessions/2026-10-13-email-imap-executor-c2.md`，列出真实生产接口、错误/世代/取消契约、C3 接续示例、计时、脚本服务端覆盖、残余限制与红绿证据。必要文档随代码提交，不修改本文、不 push、不发布、不开始 C3、不委派。最终回报 commit、测试、清理与报告路径。

### 任务 C3a：独立同步与账号服务（已签收）

执行者：新 Herdr tab 中 Codex，当前 master。先读原计划全文尤其 §4/§5/§6C、A 笔记、C1/C2 session 与相关实际源码/测试。C2 报告 `kb/sessions/2026-10-13-email-imap-executor-c2.md` 是身份、stop_timeout、closed/failure、线程及离线 render 接口的依据。本次只做服务层，不新增 HTTP 路由、不接进程生命周期、不改 App、不宣布 /status mail feature、不访问真实账号。

目标：提供给 C3b 直接接线的 MailService 和共享类型；同步、未读、缓存、通知 pending/ack 与账户生命周期均有先失败后通过的行为证据。服务使用真实 C1 Store 和可注入 C2 adapter factory/时钟/emit，自动测试主要使用 fake IMAP；不重新造一套存储或协议库。

完成条件：

- 首次配置生成 UUID mail_account_id，地址/账号配置持久化但密码仅 SecretStr 内存；更换地址停止旧任务并清旧缓存，迟到结果不得重新创建旧账号或污染新账号。后端重建服务后 credential_missing，已有缓存/水位保留；只注入同账号密码幂等、不重置基线；错误账号 id 拒绝。测试连接不保存配置并必定清理试连资源。移除清理仅邮箱数据，返回足够信息供 App 清理钥匙串/通知。
- 状态 unconfigured/credential_missing/connecting/online/offline/auth_failed，最后同步时间与全 INBOX 未读快照/过期标记；断网保留缓存/旧计数，auth_failed 停止重试直至凭证变更，网络有限退避。不依赖聊天是否登录或 Service._every；所有 Store 写入/emit 在事件循环，协议和 MIME 在 C2 工作线程。
- 首次 SELECT 以 UIDNEXT 建立历史/通知基线，取全箱 UID 与 UNSEEN，最近 100 摘要；初始化期间新增 UID 不漏不重。摘要回填/历史分页不发通知；后续 50 条按 UID 列表切片，缓存 page 不冒充全箱已同步，UID 间断/移动/删除时游标稳定或明确过期。
- 每轮对账：全箱 UNSEEN 修正缓存 flags/计数与已读目标；新 UID 按水位过滤，防 n:* 最后 UID 误报；缓存存在分批至 C2 100 UID 上限求差；UIDVALIDITY 变化重建与静默新基线，失效旧正文/游标/目标。无 CONDSTORE 按基础查询工作，不实现未经支持的扩展。
- IDLE reconcile_needed/closed 与周期 45 秒对账、无 IDLE 新信不超过60秒、手动 refresh/reconnect 合并；睡眠唤醒接口行为留 C3b/App，但服务提供强制更换连接能力。保证周期/分页/正文不创建并发同连接命令或多个后台循环。持续推送可合并，不能忙等占用事件循环。
- C2 stop_timeout 的无句柄 DNS 特例必须在生命周期顶层处理，不能无限 await 或不断创建新 daemon；退役旧实例且丢弃结果，明确限制重试在旧所有者清理前的行为。清理 render-only 工作线程；服务 stop 的集成测试满足本机进程退出要求，不能依赖默认线程池。
- 正文读取无已读副作用，cache hit 用 get_raw_body + 工作线程 render，可离线；网络 miss 用 body(key, part)，检查当前账号/连接/UIDVALIDITY，单封畸形占位/错误不阻塞其他邮件。线上库级 parser 退役时设计有限的缩批/单封隔离，避免一封坏邮件永远阻塞后续好邮件或重试风暴；回归测试覆盖。
- 显式 read 只有 STORE 核实成功才更新缓存并做 UNSEEN 对账；失败不伪报，离线不持久化待写队列。read 期间账号/世代变更和邮件删除必须拒绝迟到成功。返回新已读 id 供清理通知；不从 read 正文自动调用 read。
- 通知合格：仅新到达未读；首次导入/回填/旧邮件变未读/UIDVALIDITY 重建静默。pending 写入与同步进度原子，发事件不即 ack；无订阅者/重启仍可从状态快照恢复。超过3封或最早 INTERNALDATE 比发现早10分钟，合成稳定批次的汇总，否则逐封。重复事件/重连/ack 不能重放已确认邮件；账号/文件夹/UIDVALIDITY/id 贯穿事件/状态，read/删除剔除已失效 pending。
- 提供 C3b 用的安全领域事件 mail.status/mail.updated/mail.arrived 及状态快照，更新事件包含新已读邮件 id；emit 可注入且不绑定现有聊天 Service。事件/错误不含凭证，不记录原始异常 cause/库响应，邮件认证不会转成聊天 AuthExpired。
- 先失败测试覆盖上述可观察行为：初始化间隙到达、重启/无订阅者 pending、乱序 ack、过期世代、迟到结果、跨端 flags/删除、全箱未读与分页独立、刷新合并、断线/认证/退出。复用 C2 专项结果，不无意义重跑真实探路；后端全量 uv run pytest。
- 允许对 C1/C2 做有失败复现的必要接续修正，但不随意重写或改变契约；记录实际差异供 C3b/D。共享 Pydantic 模型放 mail/types，API 命名按原计划预备但不让 FastAPI 混入服务。
- 写 `kb/sessions/2026-10-13-email-sync-c3a.md`，明确生产方法/数据/事件、C3b 接线示例、持久化策略、测试红绿日志、未验项与决策；必要文档和实现同次提交，不修改本文、不 push、不发布、不开始 C3b、不委派；清理资源，在 tab 汇报 commit、测试、报告和工作区状态。

### 任务 C3b：API/SSE 与进程生命周期接线（已签收）

执行者：新的 Herdr tab 中 Codex，当前 master。先读根 AGENTS.md、原计划全文、C1/C2/C3a session，尤其 `kb/sessions/2026-10-13-email-sync-c3a.md` 的生产方法、事件、停止限制；再读现有 api/main/service 的实际接线方式。C3a 基线 `3f755b7`，全量 221 项通过。此 brief 由 coordinator 编写，拆分顺序不改变原计划。

目标：将已有 MailService 接入现有本机服务，让后续 App 执行者有经过真实 HTTP/SSE 验证的稳定契约。保持聊天兼容、独立故障域，完成后仍不宣称 App 邮箱功能可用。

完成条件与范围：

- 先写失败行为测试，再接原计划本地接口表的全部 `/mail/*` 路由；请求/响应使用共享 Pydantic 类型，密码 SecretStr。明确 HTTP 方法、字段、默认值、响应和错误码，供 D1/D2 直接编解码。接口草案可按实际服务合理调整但须逐项说明，不能遗漏功能。
- `/status` 原字段兼容，features 包含 mail。邮箱全部端点与 SSE 沿用现有 token 鉴权；没有/错误 token 拒绝，包括试连和凭证注入。正文 GET 不触发 Seen；只允许 INBOX 内容，校验不透明 id/cursor/账号/UIDVALIDITY；过期或错账号返回安全 mail 域错误。
- 邮件错误 `{domain: "mail", code}`，不使用 409，不转聊天 AuthExpired；HTTP 映射区分无配置/离线/失效凭证/不存在/过期/超限等且不给客户端原始库 cause。保留聊天 detail=logged_out 的既有语义。
- `/mail/account*` 的请求校验错误不得回显 body、input、密码或含密码的 ctx； malformed JSON、嵌套错误、错类型、额外字段都要有合成秘密测试。安全错误模型不含 SecretStr 本身；日志、traceback、HTTP 错误前200字节均不能泄漏凭证。修改全局 validation handler 时保留其他端点兼容。
- 生命周期中在事件循环创建独立 mail.db/Store，start 邮件服务与聊天登录无关；启动恢复 credential_missing，App 注入不重置水位。stop 先停止邮件任务再关闭 Store，网络/render/试连并行收敛。邮件网络/认证故障不阻止 HTTP、聊天启动、登录或 SSE；不复用聊天在线专属定时器。
- 单一 SSE 分发两领域事件，MailService emit 非阻塞不抛异常，有界队列满和订阅取消可收敛；无订阅者或丢事件不能 ack/丢 pending。每次重连由客户端 GET status 恢复，文档说明 generation 仅本进程内有效，后端重启需要重置比较基线。邮件数据不得错误封装成聊天事件或触发登出。
- 配置/修改地址响应交付新账号及 removed_account_id；删除、注入、试连、手动同步/reconnect、分页、正文、read、ack 按 C3a 调用，异步取消不泄漏试连/所有者。不要把测试连接成功当配置保存，不把 configure 返回当 online。端点合理处理同步等待和状态可见性，说明耗时与可重试契约。
- 用真实本机 HTTP/SSE 服务 + 合成 IMAP/可控适配器 + 隔离临时数据进行端到端测试：聊天未登录仍能配置和同步、mail auth_failed 不影响聊天、token、422 防泄漏、重启注入/pending、客户端断开/队列背压、read 与 GET 区别、旧账号/世代拒绝。只 ASGI 模拟不能冒充真实监听/流式连接证据。
- 在进程生命周期实际接线后验证完整进程停止，包括阻塞邮件 I/O 和进行中的试连；复用 C2/C3a 工具，明确实际父进程计时是否满足2秒。对 DNS stop_timeout 保持有界退役，不重建无限 daemon。必要接续修复先复现，再修，记录契约变化。
- 跑 backend 全量 uv run pytest，必要的独立后端安装/入口冒烟按变更选择；不改 App，不跑 formatter/style linter，不读取真实 env/账号、不发送或修改真实邮件、不启动用户 App、不 push/发布/开始 D、不委派其他 agent。
- 只修改本阶段后端及必要文档，协调文档只读。写 `kb/sessions/2026-10-13-email-api-c3b.md`，留 D1/D2/E 可直接消费的完整 wire 示例、字段与错误映射、事件/通知确认规则、生命周期证据、红绿日志、偏离、自主决策及「交给协调者」。合成样本/日志放 `tmp/2026-10-13-email-api-c3b/`，不用真实邮件。
- 更新 AGENTS.md/README/原计划有证据的状态，范围外问题记报告或按 kb 规则登记；实现与文档一起提交，仅暂存自己文件。关闭自建服务器/连接/进程，保留用户资源。在 tab 最终报告 commit、测试、报告路径、清理与工作区状态；coordinator 会等待稳定结束并审核后派 D1。

### 任务 D1：邮箱配置、MailState 与钥匙串恢复（自动交付已签收）

执行者：新 Herdr tab 的 Codex，当前 master。必读根/mac AGENTS.md、原计划全文、B 实现及独立验收 session、C3a/C3b session，尤其 `kb/sessions/2026-10-13-email-api-c3b.md` 的全部 wire/错误/SSE 契约。C3b 基线 `f48e5ed`，297项后端测试和真实HTTP/IMAP/完整退出验证通过。使用适用 SwiftUI、impeccable、kb 技能。本 brief 由 coordinator 编写，D1/D2 分界为实施拆分，不改变用户产品范围。

目标：Email 模块可配置独立邮箱、测试连接、保存/更新专用密码、移除账号，正确处理旧后端、钥匙串状态、后台同步及重启凭证恢复。为 D2 阅读器和 E 通知提供经过行为测试的 MailState/模型/调用接口。

完成条件与范围：

- 先写逻辑失败行为测试，再实现 Core 邮件模型/事件/错误编解码和 App 状态调用。使用 C3b 合成 wire 样本交叉校验；Unix时间、可空字段、错误占位、id/cursor、attachments、pending整批结构准确；不要由 Swift 自行重编后端 id。Core 不依赖 AppKit/Security/WebKit。
- BackendClient 加 typed 邮件 API 和安全 mail 错误映射；保留仅409 detail=logged_out触发聊天登出，401本机token与403邮箱凭证错误分开。URL路径/查询安全编码，密码仅请求体、不出现在日志/错误/描述/UserDefaults。客户端超时留出后端30秒请求加约1.5秒清理，超时后重新取状态，不推断 configure/STORE 没发生。
- 建立 @Observable MailState 及清楚的账号/连接世代防护，接入 AppState 唯一SSE：mail.* 独立分派，连上后分别刷新聊天/邮箱，不受聊天登出限制。后端更换/重启重置 generation 比较基线；账号切换、移除、旧请求晚到不得覆盖新状态。不要新增第二条 SSE 或把全部逻辑塞回 AppState。
- 实施 file-based SecItem 钥匙串，不设 kSecUseDataProtectionKeychain；以 mail_account_id 精确存取，邮箱地址仅附加属性。区分找不到、用户拒绝/认证失败、锁定与其他错误。用可注入包装测试这些结果；不得为了测试读取/覆盖/删除真实条目或触发用户授权弹框，不回落明文。
- App启动对当前账号自动读钥匙串一次，随后密码只驻内存；后端 ready 且本次SSE已连上才注入，重复状态/重连幂等，后端崩溃重启复用内存凭证不反复读钥匙串。缺失/拒绝/锁定提供清楚提示和用户重试入口，显式重试可以重新访问钥匙串；不得后台忙重试或反复注入同一失效密码。
- 外部后端模式 FEISHU_LITE_BACKEND_URL 不自动读取/注入钥匙串；配置页允许手动输入。测试账号 UUID、独立UserDefaults/假Keychain；不读取 tmp/feishu-mail.env，本阶段不接真实邮箱。环境操作先 envops。
- 配置 UI 使用当前原生风格：邮箱地址、SecureField专用密码、测试连接、保存、修改凭证、移除；飞书主机/端口预设不做通用邮件工具。测试连接不保存，显示 writable/只读限制；保存返回不冒充online。合理禁用重复提交、显示进度/可恢复失败，避免把底层错误码原样当产品文案。
- 配置与聊天账号明确独立。首次保存取得后端 UUID 后写对应钥匙串；写失败必须保留可重试的准确状态，不能声称已安全保存。更换地址/移除根据 removed_account_id 清理旧钥匙串及内存/选择，只匹配旧账号；清理失败不得静默丢失追踪。通知清理接入现有命名空间能力或留经过测试的 E 接口，报告准确边界，不大范围删除钥匙串。
- unconfigured/credential_missing/connecting/online/offline/auth_failed分别展示；断线/认证失败保留计数与缓存状态，呈现最后同步及过期提示。features不含mail时显示现有后端安装命令及重新检测，不显示成普通网络失败，不对旧后端请求邮箱端点。未知/加载中能力不能提前读钥匙串。
- 将MailStatus整箱计数接入唯一 AppState.updateUnread，配置/移除更新归零而普通离线不清零；这是D1状态接线，E仍负责完整通知/唤醒联动与回归。保留 pending 并提供E入口，本阶段不提前 ack 未投递/未按可见性抑制的批次。
- D1不实现完整邮件列表/正文/WebKit/可见性已读，配置后可显示准确同步状态与后续阅读器占位。为D2留实际选择/滚动锚点/正文加载状态的接入接口，B 的 pendingMailRoute 不能作为邮件已显示/已读证据；此阶段不得意外调用 read。
- 自动测试覆盖真实调用点：两模块独立、ready/SSE顺序、重启只注入不重新读钥匙串、旧后端、外部模式、凭证三类异常、重复保存/晚到试连/账号切换、钥匙串写删失败、无凭证泄漏、badge与pending不误ack。运行 cd mac && make test && make build；不要只测没有被调用的纯函数。必要后端变更须有复现与相应测试，不重新探路/主动格式化。
- 本tab不启动实机UI验收；用户要求验收开独立tab，配置UI及真实SecItem/权限证据留独立验收。不运行会杀用户App的make run，不改变签名/bundle id，不push/发布/开始D2/自行委派。测试假资源结束清理。
- session写 `kb/sessions/2026-10-13-email-configuration-d1.md`，证据 `tmp/2026-10-13-email-configuration-d1/`；完整记录接口、凭证状态机、自动测试红绿、真实未验、自主决策、D2/E接续及「交给协调者」。更新必要AGENTS/README/原计划有证据条目，代码文档同次提交，仅暂存自己的文件；不改本文。在tab回报commit、测试、报告路径、清理和工作区状态，coordinator签收后另派D2。

### 当前任务 D2：收件箱阅读器、安全正文与可见性已读

执行者：新的 Herdr tab 中 Codex，当前 master。先读根/mac AGENTS.md、原计划全文尤其§3/§5/§6D/§7、B实现/验收、C3b和D1 session。D1基线 `bf490b8`，Core70+App26测试/Debug构建通过；`kb/sessions/2026-10-13-email-configuration-d1.md` 是 MailState、合并任务、选择和凭证边界的实际依据。使用适用SwiftUI/impeccable/kb技能。本文为coordinator拆分，产品范围不变。

目标：Email工作区可读取收件箱摘要和正文，按需分页，安全展示HTML/纯文本及附件元数据；只有正确目标的正文成功显示且满足ViewingContext时才提交已读。保留D1配置和恢复能力，为E通知路由接续，实机独立验收由coordinator另派。

完成条件与范围：

- 逻辑先写失败行为测试，使用C3b真实wire与D1 typed API；在现有MailState上接续，不另造并行邮箱状态或第二条SSE。账号、连接epoch、UIDVALIDITY、当前选择、请求代次一起防迟到响应，后台refresh合并有界，不对每个事件创建任务。不要阻塞唯一SSE消费。
- 原生邮件双栏：列表列顶部全部文件夹下拉，保持中文层级及标识；只INBOX可读，其他文件夹及Noselect禁用并清楚提示，不展示虚假未读。列表行含发件人/主题/收件时间/未读/附件，长中文与空值回退，按UID顺序不自行按Date重排。
- 初始最多100、下一页50，透传不透明next_cursor；重复请求/重连/新信插入无重复或错误丢项，分页与全箱badge独立。刷新/reset/删除/过期cursor正确失效并恢复列表，账号移除清选择；离线缓存和未缓存正文错误区分。手动刷新、同步状态、最后同步和过期提示保留；首次not_synced/空文件夹不误报没有邮件。
- 配置入口可继续打开D1表单，已配置默认阅读工作区。模块切换重建视图但状态保留选中、列表首可见行、详情滚动位置；有稳定锚点方案。保持窄导航、最小800×460、聊天草稿/键盘隔离和现有原生视觉。不把实现术语暴露到正常用户界面。
- 详情显示主题、发件/收件/抄送、时间、正文、附件基本信息；未知大小省略或标明约数，不下载/预览附件。纯文本按纯文本显示；空正文/错误占位有明确状态。正文GET无已读副作用，UI正在加载或失败时不能发read。
- HTML后端已净化但App仍完整隔离：非持久WKWebsiteDataStore，禁用页面JavaScript，无本机token/其他账号数据注入；严格CSP和内容规则阻断全部网络/本地资源，规则编译并成功挂上之后才加载第一封。规则失败必须fail closed给可重试错误，不先显示后补保护。使用公开API，不靠私有配置。
- 拦截自动导航、表单、iframe、file/data/javascript/custom等scheme；只有真实用户点击合法HTTP(S)才经外部浏览器打开，target=_blank通过WKUIDelegate接续。合法内网/IP的HTTP(S)链接不额外禁用；不得自动请求链接预览。远程/CID内嵌图片保持占位与文本，不增加加载远程图片开关。
- 正文“成功显示”由实际渲染完成确认：纯文本对应当前视图出现，HTML对应当前WK加载成功；只拿到HTTP200不能等同已显示。回调必须校验当前账号/邮件/渲染代次，旧WK完成回调不得标新邮件。离开Email/切目标/窗口关闭/后台/渲染失败不提交read；回到可见前台时重新判断。
- 在AppState.reevaluateViewing与既有激活/窗口/key/切换入口补MailState read。统一ViewingContext决定已读与后续通知抑制，不能从pendingMailRoute推断正文可见。显式read去重、失败不伪清计数、不排离线写队列；超时/410/404重新核实状态和目标，防止无限重试。状态计数仍取整个INBOX快照并走唯一badge入口。
- 提供E可调用的邮件/INBOX路由加载入口及目标失效回退；目标不在当前页可按id加载正文，摘要元数据获取策略需与已有API一致，不凭空拼邮件或下载全箱。若需新增后端按id摘要能力，先报告当前契约限制并在本任务做最小有测试接续，说明变更；不要让通知误开同UID另一封。实际通知投递/ack/唤醒仍留E，不提前确认pending。
- 自动测试至少覆盖分页/刷新交错、切模块/后台/隐藏窗口不read、成功显示后read一次、快速切邮件/账号、WK迟到成功、离线正文/失败read、旧cursor/目标删除、HTML规则未就绪不加载/失败封闭、导航与_blank允许/拒绝、旧后端及D1凭证恢复回归。不要仅测没有实际调用的策略函数；Core纯逻辑无AppKit/WebKit，系统胶水在App层。
- 运行 cd mac && make test && make build；若有后端接续修改，先行为测试再实现并跑后端全量。网页资源零请求/JS不执行等真实WebKit证据不能只靠纯函数冒充，留明确独立验收清单和可复用合成样本/计数端点；本tab不启动实机UI，coordinator另派。不得读取真实env/邮箱/缓存，不改真实flags，不make run、不改签名或bundle id、不push/发布/开始E/自行委派。
- 报告 `kb/sessions/2026-10-13-email-reader-d2.md`，证据 `tmp/2026-10-13-email-reader-d2/`；写清生产接口、异步/渲染/已读契约、安全策略与自动测试边界、E接续、独立UI/WebKit检查、自主决策及「交给协调者」。必要文档随实现一起提交，只暂存自己的文件、不修改本文；清理自建测试资源，最终在tab回报commit/测试/报告/工作区状态。

### 状态

- [x] A：已签收 `3cbc23d`；7 个测试、42 次计时通过；真实已读/通知等仍按原计划待验。
- [ ] B：实现 `66312a9`；独立验收 `a05dcb8`，核心外壳可进入 C，无产品缺陷待返修。系统通知/点击、Dock 实际显示、真实输入法及 supervisor 启动回归留 F，故全项未勾选。截图 `tmp/2026-10-13-email-reader/b-acceptance/`。
- [x] C1：`2efd0be`，后端全量 123 项通过；按协调审阅保留合法 HTTP(S) 内网链接，未接通 API/同步。
- [x] C2：`b1dd3ce`，后端全量 179 项通过；36 次时限测量全部 <2秒。DNS stop_timeout/closed/failure 等接续约束必须由 C3a 实施。
- [x] C3a：`3f755b7`，后端全量 221 项通过（新增42项）；4个完整进程停止场景最大1.524秒。服务层已签收，API/App/真实验证尚未完成。
- [x] C3b：`f48e5ed`，后端全量297项通过；真实HTTP→IMAP FETCH 0.110秒，5个完整进程退出最大1.685秒，独立wheel安装/CLI冒烟通过。App接入及真实邮箱尚待验证。
- [x] D1：`bf490b8`，Core70+App26项测试及Debug构建通过；配置/钥匙串包装/重启恢复/有界SSE自动交付签收。真实SecItem与UI保留F独立验收。
- [ ] D2
- [ ] E
- [ ] F
