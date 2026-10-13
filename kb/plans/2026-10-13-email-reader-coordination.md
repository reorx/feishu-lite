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
| C3 | 同步、账号生命周期、API/SSE、待提醒与 ack | 原计划 C 的同步、错误隔离、凭证防泄漏行为测试 |
| D1 | MailState、配置 UI、钥匙串、重启注入 | 状态/注入测试、隔离与错误路径证据 |
| D2 | 文件夹/列表/正文、WebKit、可见性已读 | 安全展示与迟到请求测试、构建通过 |
| E | badge/通知/路由/唤醒集成 | 跨模块、重连去重、清理和账号移除测试 |
| F | 新 tab 独立整体验收与逐项返修 | 全套测试、隔离 UI 截图、授权范围内真实接入、回归和最终差距报告 |

顺序 A → B → C1 → C2 → C3 → D1 → D2 → E → F。任务 brief 在派发前根据上阶段实际接口落地，不让执行者猜测尚未实现的依赖。A 中需指定测试邮件的验证可保留至 F，不阻塞隔离开发。

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

### 当前任务 C1：邮件领域模型、存储与 MIME 解析

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

### 状态

- [x] A：已签收 `3cbc23d`；7 个测试、42 次计时通过；真实已读/通知等仍按原计划待验。
- [ ] B：实现 `66312a9`；独立验收 `a05dcb8`，核心外壳可进入 C，无产品缺陷待返修。系统通知/点击、Dock 实际显示、真实输入法及 supervisor 启动回归留 F，故全项未勾选。截图 `tmp/2026-10-13-email-reader/b-acceptance/`。
- [ ] C1
- [ ] C2
- [ ] C3
- [ ] D1
- [ ] D2
- [ ] E
- [ ] F
