---
created: 2026-10-14
tags:
  - email
  - notifications
  - recovery
  - testing
---

# 邮箱 E：通知确认、精确清理、路由与唤醒联动

## 概要

在 master 的 D2 基线 `fedbc8b` 接续完成 E。邮件提醒从后端持久 pending 驱动，通过可注入系统边界投递；整批全部成功或明确抑制后才 ack。部分投递失败保留成功项，确认失败只重试确认。通知点击等待能力与完整邮箱身份，唤醒经同一后端合并重连。Core 74、App 67、后端 301 项通过，Debug 构建成功。本 tab 没启动 App、系统通知、实机验收或 F，也没访问真实邮箱、凭证、缓存或钥匙串。

协调审阅发现早期 interruptedIntent 测试把投递前的 intent 当成功，已按用户要求先写失败复现再修正：未知结果保留 pending、不自动重弹、不 ack；Email 提供“再次提醒”并说明可能重复显示。该测试的早期通过日志不属于最终正确性证据。

## 修改的文件

- `mac/FeishuChat/Services/LocalNotificationCenter.swift`：统一 authorization、delivered/pending 查询、add 和按 id 移除，生产包装 UNUserNotificationCenter，测试注入 recorder。
- `mac/FeishuChat/Services/MailNotificationCoordinator.swift`：一个串行合并任务、持久处理记录、权威 pending 核实、投递/确认、重启恢复与精确清理；独立于聊天登录。
- `mac/FeishuChat/Services/NotificationService.swift`：聊天投递/清理也经过同一包装，保留升级前 chat_id 与 session-expired 兼容，权限变化唤醒邮件处理。
- `mac/FeishuChat/Model/AppState.swift`：接线 MailState hooks、通知路由任务、workspace 唤醒与观察者退出清理；仍只有一条 SSE、一个 badge 入口。
- `mac/FeishuChat/Model/MailState.swift`、`MailState+Reader.swift`：处理批次读删/reset、版本保护的 ack 快照、精确账号及本地 read 清理接口。
- `mac/FeishuChat/Services/BackendClient+Mail.swift`：缓存摘要查询的 404/410 表示目标失效，其他错误保留并重试，不触碰正文/Seen。
- `mac/FeishuChat/UI/EmailWorkspace.swift`、`RootView.swift`：未知结果计数和明确再次提醒入口；已知临时失败提供重试提醒。使用原生布局，实际提示排版留 F。
- `mac/FeishuChatCore/Sources/FeishuChatCore/MailNotificationPolicy.swift` 及对应 Core 测试：完整批次身份与统一 ViewingContext 抑制策略，无 AppKit 依赖。
- `mac/Tests/FeishuChatStateTests/MailNotificationTests.swift`：21 个真实 AppState/Model/Services 调用测试，URLProtocol、通知 recorder、假凭证与独立偏好；既有 MailIntegration/MailReader/ModuleIntegration 测试也改为显式注入通知 recorder，避免触碰系统中心。
- 根/mac AGENTS、README、两篇领域文档、原计划 E、known-issues、next-up：同步当前实现与未验边界；协调文档只读，未修改。后端源码和接口未改变。

## 注意事项

### 投递、去重与确认

处理入口是 MailState 的 status/arrived/read/delete/reset/账号变化，以及 SSE 恢复与通知授权变化。MailNotificationCoordinator 的一个任务合并事件；500 次重复 arrival 在慢 add 期间仍只有一个 add、无提前 ack。每轮先 GET `/mail/status` 核实持久 pending，避免本地 receipt 淘汰后迟到 SSE 复活已确认批次。HTTP 快照只在账号/epoch/UIDVALIDITY 与 MailState revision 匹配时应用，迟到 ack 不反向覆盖新事件。

原样消费后端 mode/batch id：individual 按完整邮件 id 显示发件人和主题，不下载正文；summary 一条、数量来自当前批次，路由 INBOX，不重新分类。后端阈值仍为超过 3 封或最早 INTERNALDATE 超过 600 秒，App 不用 Date 重新切批。自己发给自己仍通知；只有同一成功显示正文的 ViewingContext 才抑制，裸选择/待路由/HTTP 200 不算。历史、分页、标志变未读、重建无 pending 不产生通知。

通知 identifier/thread 使用已有 `email:` 加账号/文件夹/邮件或批次的 base64 组件，与 `messages:` 分离。userInfo 除原路由外增加 `mail_batch`、`mail_uidvalidity` 和 JSON 字符串 `mail_members`，用于精确恢复；没有正文、密码或 backend token。

`mail-notification-receipts-v1` 在 App 偏好中记录 id、账号、UIDVALIDITY、batch、members、handled、acknowledged 和时间，禁止保存主题/发件人/正文/凭证。状态如下：

| 状态/证据 | 后续行为 | 可 ack |
| --- | --- | --- |
| 无记录且仍在权威 pending | 持久化 handled=false intent，再调用 add | 否 |
| add 返回成功，或重建查询到身份/id/批次/成员精确匹配的中心条目 | 持久化 handled=true receipt，不再 add | 整批其余项也已处理时可以 |
| 通知权限明确 disabled，或当前实际显示同封正文 | 明确抑制，持久化 handled=true | 整批其余项也已处理时可以 |
| 权限 undecided | 保留 pending，授权变化后继续 | 否 |
| add 明确抛错 | 只移除此次 active intent，下次同步/重试提醒可再 add | 否 |
| 重建读到 handled=false、中心无精确条目 | 未知 intent，保留 pending 和恢复提示，不自动 add | 否 |
| handled=true 但 ack 失败/超时 | 保留 receipt，下一次核实后只重试 ack，中心已被用户关闭也不重弹 | 可以重试 |
| 后端已确认/成员已读删/reset/账号移除 | 以权威身份清理关联；不会将未知结果虚构为投递成功 | 不需要伪造确认 |

“再次提醒”只由用户显式触发：先重新查询中心，有精确证据的 intent 直接恢复为成功；对仍未知的 intent 移除旧记录并重新执行投递/抑制。文案明确再次显示可能重复。若该次 add 明确失败，清除新 intent，正常重试可恢复，不能把旧 intent 留着误判成功。不同成员/HTTP 操作失败不能清除其他未知记录。未知项可以跨重启一直保留；不会通过后台忙重试自行选择“可能重复”或“可能丢失”。

已处理记录上限 2048，只淘汰 acknowledged 且后端不再 pending 的最旧项，并移除其中心条目；未确认/未知记录不淘汰。容量被未确认记录占满时停止新 add，保持 pending，提示下次同步重试。读删可能使后端直接移除整批，权威 pending 已不含某个未知 batch 时其 intent 可清理；这属于目标不再待提醒，不能描述为成功投递。

### 崩溃窗口与恢复策略

| 中断位置 | 重建证据与处理 | 测试证据 |
| --- | --- | --- |
| intent 持久化之前 | 无记录且 pending 仍在，可尝试投递 | 普通首次投递/重连 pending 测试 |
| intent 已持久、add 尚未调用或结果未回；中心也无条目 | 无法区分尚未投递、已投递后被关闭等情况，保持未知、不 ack、不自动重弹，提供明确恢复 | interruptedIntentWithoutCenterEntryStaysPendingAcrossRecovery |
| 系统已接受、成功 receipt 尚未保存；中心条目仍在 | 精确匹配中心元数据恢复成功，不再次 add，然后确认 | interruptedIntentWithExactCenterEntryIsConfirmedWithoutRepeating |
| 系统已接受、receipt 尚未保存且中心条目已被关闭/清除 | 同上未知状态，明确再次提醒可能重复；绝不把未知冒充成功 | 无条目 intent 测试覆盖该证据状态，不声称模拟证明真实系统时间窗口 |
| add 明确失败、错误处理尚未持久清除即崩溃 | 重建仍可能只有 intent，按未知保留；运行期间收到明确失败则清该次记录，可自动恢复重试 | actualOldEpochAddFailureClearsOnlyItsIntentAndCanRetry；未知 + 另一成员失败/明确恢复失败测试 |
| 成功 receipt 已存、ack 前或 ack 失败 | 不重弹，只确认；成功通知被用户关闭也如此 | partialDeliveryAckFailureAndRestartNeverRepostSuccessfulMembers |
| 后端 ack 成功、本地响应/acknowledged 保存前 | 权威 status 已无 pending，不再投递；现存提醒仍按摘要/read/delete 恢复清理 | summaryUsesBackendBatchAndRestartRecoversMissedReadsAfterAck；迟到 arrival 测试 |
| 旧任务 add 期间移除/reset/更换账号或后端重启 | 旧所有者仍串行等待完成；匹配当前账号/UID 的成功保存 receipt，否则精确移除迟到条目；明确失败仍清自己的 intent | removedAccountCleansLateAddAndKeepsMessages；reset 慢查询；旧 epoch add 失败测试 |

UserDefaults 持久化、系统 add 和 HTTP ack 无法组成原子事务。synchronize 是尽力持久化，不提供事务/掉电证明；系统 accepted 也不等于用户实际看到 banner。稳定 identifier 可能仍触发再次显示。这里证明的是有证据才确认、未知保留和明确恢复，没有声称 exactly-once。损坏或人为删除本地 receipt、系统中心同时无条目时无法再获得原成功证据，仍可能重复；真实系统崩溃/授权/点击留 F。

### 清理、路由、badge 与唤醒

- read_ids/deleted_ids、显式本地 read、reset、UIDVALIDITY 改变和账号移除只移除匹配邮件领域条目，包括已递送和待递送。升级前聊天 chat_id 保留兼容，聊天清理不碰邮件，邮件移除不碰聊天。
- 重启/恢复不仅看 pending：扫描中心及持久 receipt，对仍在中心的成员调用缓存 `/summary`，已读或 404/410 即清理。summary 任一成员已读/失效时移除整条，保留成功处理状态，避免再补一条汇总；暂时查询失败保留提醒，下次状态更新再核实。
- 点击先开窗口、切模块，一个合并路由任务等待支持能力、ready、匹配账号及单封 UIDVALIDITY；重复/迟到请求只消费最新路由。复用 D2 按 id 摘要/正文；404/410/旧账号返回可用列表并提示，summary 回 INBOX。目标加载不等于显示，也不自动 read；账号移除中途使迟到选择无效。
- badge 仍只从 AppState.updateUnread 发出。测试整箱 321 与聊天 7 合计 328（显示 99+），offline/auth_failed 保留邮件 321，移除邮件后总计 7；B 的静音/隐藏/0/99+ Core 与调用测试回归通过，不从通知/当前页推算计数。
- workspace didWake 使用同一 BackendClient `POST /mail/sync?reconnect=true&wait=true`，100 次唤醒合为一次重连；初始能力未知时保留意图，能力/状态可用后执行。完成后刷新权威 status/pending，并重新判断已显示正文的 D2 可见已读。无第二条 SSE，不读钥匙串/触发聊天 QR，关闭窗口不停止后台；shutdown 取消新增任务并移除 default/workspace 对应观察者。失败核实状态后等待下次恢复，不忙循环。

## 自动验证与证据

所有证据在 `tmp/2026-10-14-email-notifications-e/`（gitignored）。最终结果：

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `cd backend && uv run pytest` | 301 passed，48.31 秒 | backend-full.log |
| `cd mac && make test` | Core 74 / App 67 passed；其中新通知 suite 21 项，覆盖参数变体 | tests-final.log |
| `cd mac && make build` | Debug Build Succeeded | build-final.log |
| `uv run --project backend python tmp/2026-10-14-email-notifications-e/notification_fixture.py --check` | 合成 loopback arrive/ack/reconnect 冒烟通过，退出关闭 listener；无 App/通知/IMAP | fixture-smoke.log |
| `git diff --check` | 通过 | 提交前运行 |

红绿记录：

- `tests-red.log` 是初始行为测试缺接口的编译红；`tests-first.log` 含 fixture 写私有 pending 的编译问题，不能把这两份都冒充运行时复现。
- `tests-first-green.log` 虽文件名含 green，实际捕获 NSApp nil 崩溃；AppState 使用可选 NSApp 默认后台后通知测试才通过。
- `tests-reset-wake-red.log` 运行时 5 个失败，复现 reset 的迟到中心查询、能力未知后的唤醒及初始无 UID 路由；对应修复后通过。
- `tests-durable-pending-red.log` 运行时 2 个失败，复现 receipt 淘汰后的迟到 arrival 再次投递/确认；修复每轮权威 pending 核实后通过。
- `tests-uncertain-red.log` 运行时 4 个失败，复现未知 intent 错 ack、pending 被移除、handled/acknowledged 被误标真。`tests-uncertain-green.log` 是修正后的 21 项通知专项，包含未知保留/明确恢复、已知失败重试、精确中心证明与旧 epoch 失败清理；最终全量见 tests-final.log。
- `tests-full-first.log` 含 D1 空批次兼容回归失败，已修复保留权威空 pending，最终通过。早期中间日志保留用于审阅，最终测试数量/正确行为以 tests-final.log 为准。

后端未改，但全量复跑覆盖 `tests/mail/test_service.py::test_notification_thresholds_use_received_time_and_stable_batches` 的 3/4 封与 600/601 秒四个边界、首次历史静默、跨端 flags/删除/reset、无订阅者 pending 与重启/乱序 ack。App 的 21 项额外覆盖自己收件、仅同封显示抑制、权限 disabled/undecided、部分 add/ack 失败、重启且通知被关闭、500 重复事件、晚到 add、漏失事件清理、namespace、页外/失效/最新点击、旧后端/D1/D2 回归、双 badge 和唤醒观察者退出。

测试持有的 continuation、HTTP client、独立 UserDefaults 在 harness defer 中释放。无截图，因为未启动 UI；recorders 通过不代表实际通知投递/点击或提示布局通过。

## 自主决策

- 接续现有后端契约，没有新增 API、改阈值、扩展其他文件夹或复制已读策略。
- 增加 identity-only 处理记录而非只依赖稳定 identifier；2048 上限兼顾长期增长与未确认项保护，权威 pending 防被淘汰批次重放。
- 按协调审阅修正未知 intent，不选择静默确认；提供可操作的再次提醒入口，用户可接受可能重复的恢复结果，既不后台忙重试也不永久吞掉待处理状态。
- 汇总任一成员失效时移除整条、保留成功 receipt；避免含失效目标的提醒，不重编批次/补弹。
- 所有 AppState 测试显式注入通知包装，避免增加 E 接线后既有测试意外查询真实系统中心；未读取真实 env 或 Keychain。

## 遗留问题

实际系统通知/点击、恢复提示布局、系统权限变化、真实睡眠与实机资源退出未验，已更新 known-issues/next-up，留协调者另派 F。真实 WebKit、SecItem/Debug-Release 授权和真实跨端 Seen 仍按 D1/D2/A 待验，没有凭 E 自动结果勾选。

## 交给协调者

1. E 自动实现可以审阅签收；请另派 F 独立 tab，不将本报告当作系统投递或 UI 验收。
2. 需用户指定测试邮件及发件来源后才能验证真实新信/Seen/跨端 flags；litetest 聊天授权不扩展为邮件写入授权。没有读取 `tmp/feishu-mail.env`，未请求或使用真实密码。
3. F 可用入口是本地 `tmp/2026-10-14-email-notifications-e/notification_fixture.py`，通过 uv/backend 环境运行，依赖已有 D2 safety_fixture.py。`--check` 仅冒烟；`--serve --port 18875` 才保持 listener，F 获授权后自行启动和清理。合成 token `synthetic-e-only`、账号 UUID 尾 `e0`，所有内容均合成。有限 SSE 快照每次重连暴露 pending，`GET /control` 返回计数/acks。
4. 合成控制使用该 token 的 Bearer：`POST /control/arrive` 传 `{"uids":[161,162],"mode":"individual"}`（summary 可用 4 封）；`/control/ack-failure` 传 `{"enabled":true/false}`；`/control/read`、`/control/delete` 传 `{"uid":161}`；`DELETE /mail/account` 移除合成账号。这是原样后端批次模拟，不是阈值分类或真实 IMAP 证据。
5. F 逐项检查：逐封/汇总系统 banner 与权限关闭；Email 同封/其他封与聊天焦点；跨模块/页外/汇总/旧账号/404 点击；ack 故障后重启不重弹；读删/reset/账号移除的系统清理；未知 intent 恢复提示在最小窗口的可见性与键盘操作；明确再次提醒可能重复的文案与成功/失败恢复；Dock 实际 0/99+；关闭窗口同步与真实 didWake 重连；退出观察者/进程清理。用户系统通知或权限框真正显示前须提前告知，不改正式 bundle id/签名/授权、不清工作消息。
6. 无原子 exactly-once 承诺：实际 kill/系统中心条目消失/receipt 损坏窗口可由 F 在隔离数据中核实，未知必须保留，不能复活旧错误“无条目 intent 成功 ack”策略。完整测试 oracle 位于 MailNotificationTests.swift。

## 资源清理

合成 fixture 冒烟在 finally 中关闭 HTTP client、server 和工作线程；pytest/Swift tests/构建均退出，保留可复用脚本和日志。`ps` 未发现本任务 fixture、Swift 测试、pytest 或 xcodebuild 残留，18875 无 listener。使用 systools 的 `mac-dev-cleanup --only browser --min-age 2 --dry-run` 与 `--only sim --dry-run` 均显示 nothing to clean，再运行同范围实际清理仍 nothing to clean，日志 cleanup-browser/sim 与 cleanup-final-browser/sim。没有启动/关闭用户 App、真实邮箱连接或其他会话资源；未清构建缓存或证据。实现与本文及必要文档在 master 同次提交，只暂存本任务文件。

## 相关文档

- [邮箱阅读器原计划](../plans/2026-10-13-email-reader-plan.md) — 实施依据，仅更新有证据的 E 状态。
- [串行协调 brief](../plans/2026-10-13-email-reader-coordination.md) — 完整阅读，当前任务 E 约束，只读未修改。
- [B 实现](2026-10-13-email-shell-phase-b.md) / [B 独立验收](2026-10-13-email-shell-b-acceptance.md) — 模块/通知命名与未验边界。
- [C3a](2026-10-13-email-sync-c3a.md) / [C3b](2026-10-13-email-api-c3b.md) — pending/ack 与 wire/生命周期依据。
- [D1](2026-10-13-email-configuration-d1.md) / [D2](2026-10-13-email-reader-d2.md) — 凭证/状态与路由/正文显示/已读接续。
- [模块外壳](../docs/module-shell.md) / [邮件基础](../docs/email-foundation.md) — 同次更新当前跨模块和恢复行为。
