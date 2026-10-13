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

### 当前任务 B：双模块外壳与聊天状态拆分

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

### 状态

- [x] A：已签收 `3cbc23d`；7 个测试、42 次计时通过；真实已读/通知等仍按原计划待验。
- [ ] B
- [ ] C1
- [ ] C2
- [ ] C3
- [ ] D1
- [ ] D2
- [ ] E
- [ ] F
