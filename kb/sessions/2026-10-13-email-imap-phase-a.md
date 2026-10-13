---
created: 2026-10-13
tags:
  - email
  - imap
  - session
---

# 邮箱阶段 A：完成只读探路与 IMAP 库选型

## 概要

按 coordinator 的当前任务 A，在 master 上通过 envops 加载用户已有凭证，完成飞书邮箱 TLS、正常认证、CAPABILITY、ID、中文及层级文件夹、EXAMINE、UID 属性、FLAGS/BODYSTRUCTURE/PEEK 与短时 IDLE 的只读探路。Python 3.12.12 下比较 IMAPClient 4.1.0 和 aioimaplib 2.0.3；两个库的隔离中断和退出时限测试均通过，但 aioimaplib 的 EXAMINE 状态转换有可复现问题，因此选定 IMAPClient。只更新探路工具和文档，未实施 B–F，未修改后端依赖、App 或真实邮件 flags。

## 修改的文件

- `kb/notes/2026-10-13-email-imap-probe.md`：脱敏能力表、真实与隔离计时、候选比较、后续执行模型与未测清单。
- `kb/plans/2026-10-13-email-reader-plan.md`：只勾选有证据的 A 项，将 IDLE 选型与真实长期/跨端验证分开；没有勾选后续阶段。
- `AGENTS.md`：指向选定库及探路约束，仍明确邮箱未实现。
- `kb/next-up.md`：补充 F 真实验收前等待测试邮件和发件来源的条件检查。
- 本 session：执行交接记录。
- `tmp/2026-10-13-email-imap/`：可复用 uv 脚本、测试、结构化脱敏结果和官方文档快照；gitignored，未强制入库。

协调文档的状态由 coordinator 维护，本执行者没有修改或派发下一阶段。

## 注意事项

真实接入：系统 CA/主机名校验的 TLSv1.3；IDLE 与 ID 可用；当前账号在发 ID 前能认证及 LIST/EXAMINE。未公布 CONDSTORE/QRESYNC、ESEARCH、SORT、SPECIAL-USE、UTF8=ACCEPT。9 个文件夹里 8 个中文名称、2 个含层级分隔符，INBOX 可用。EXAMINE 的 PERMANENTFLAGS 包含 `\Seen`，但没有证明真实写入权限。抽一封未读邮件读取头部及文本片段后 FLAGS 保持不变，未下载附件。

真实 IDLE 的 1 秒等待、DONE 确认与 PEEK 完成三次分别为 1.2103、1.2276、1.2189 秒。隔离 30 次线程/任务测量和 12 次完整进程退出测量均小于 2 秒，详细最大值见研究笔记。没有把真实短时无推送当作跨端 FLAGS 不支持，也没有用模拟服务端代替真实权限验证。

自动检查：`test_probe.py` 3 个测试、`test_aio_examine.py` 1 个复现测试、`test_idle.py` 3 个行为测试全部通过。测试覆盖报告序列化、多部分 BodyData、不取文本附件、库中断/停止、整个进程退出，以及服务端能检测 DONE 确认前提前发送 FETCH 的违规客户端。42 个结构化计时结果全部满足串行、关闭及数据校验。探路中的报告序列化与多部分表示错误已先补复现测试再修正；没有主动跑 formatter/style linter。

后续实现需专用 daemon 工作线程持有 IMAPClient、命令串行、正文/已读优先，停止时以 socket.shutdown 打断阻塞 I/O，由所有者完成关闭；不使用默认线程池。普通读取的 10 秒超时不能当作 IDLE 切换时限，DONE 确认需单独期限。候选计时中 aioimaplib 使用 SELECT 仅限隔离服务端，真实邮箱全程 EXAMINE。

本次没有 App/后端功能变更，不需全项目构建或 UI 验收，也没有截图。所有自建真实连接、本地服务端、工作线程与测试子进程均已停止；没有启动浏览器或模拟器，不清理用户正在运行的 App。正式缓存、钥匙串及通知均未操作。

## 遗留问题

- 没有指定可修改测试邮件，真实 SELECT/STORE、`\Seen` 在官方端可见及重连持久化待 F 授权样本验证。
- 跨端 flags 推送、60 秒未读对账与新信通知待测试邮件及邮箱发件来源；未自行发信。
- 真实长期 IDLE 断开周期未观察；连接数上限与错误密码限流/锁号未做压力或故意错误认证探测。
- 适配器的连接建立中停止、TLS 阻塞/半行响应、持续推送公平性与完整 MIME 样本仍由后续阶段实现及测试。

这些是未交付邮箱功能的验证关卡，不作为当前 App 的新缺陷登记，未修改 `kb/known-issues.md`。

## 相关文档

- [邮箱阅读器计划](../plans/2026-10-13-email-reader-plan.md) — 执行依据，更新 A 中有证据的检查项。
- [邮箱执行协调文档](../plans/2026-10-13-email-reader-coordination.md) — 依据当前任务 A 与授权边界，阶段状态留给 coordinator。
- [IMAP 只读探路笔记](../notes/2026-10-13-email-imap-probe.md) — 本次新建的完整证据、计时方法、库选择与待验列表。
- [Next up](../next-up.md) — 更新按条件触发的后续真实检查。
