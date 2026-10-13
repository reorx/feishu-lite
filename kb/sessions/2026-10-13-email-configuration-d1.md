---
created: 2026-10-13
tags:
  - email
  - swiftui
  - keychain
  - phase-d1
---

# 邮箱 D1：独立配置、凭证恢复与有界共享 SSE

## 概要

在当前 master、C3b 基线 `f48e5ed` 上完成 D1：Email 原生配置页、Core 邮件 wire 模型与安全错误、全部 typed 邮件 API、常驻 MailState、file-based SecItem 包装、独立邮箱计数与后端重启凭证恢复。先写失败行为测试，再实现；协调补充的跨重建旧钥匙串清理、写失败密码仅留内存、有界按序 SSE 分派都覆盖实际调用点。

最终 `cd mac && make test` 通过 Core 70 项、App 26 项，`make build` Debug 通过。只完成 D1 自动实现与验证；未启动 App/实机 UI、真实邮箱、真实 SecItem 或系统授权，不宣称配置 UI/钥匙串实际验收通过。不读取 env、真实缓存/密码，不发送邮件或修改真实 flags，不委派、不修改协调文档、不 push/发布、不开始 D2。实现与本报告及必要文档同次提交，仅暂存本阶段文件。

## 修改的文件

- `mac/FeishuChatCore/Sources/FeishuChatCore/MailModels.swift`、`MailAPIError.swift`：完整邮件模型、可空字段、Unix 秒、整批 pending、后端不透明 id/cursor、安全错误和脱敏 MailSecret。
- Core `BackendEvent.swift`：解码独立 `mail.status` / `mail.updated` / `mail.arrived`，校验 SSE 名称和 payload 类型一致。
- Core `MailDecodingTests.swift`、`Fixtures/mail-wire.json`、`Package.swift`：直接交叉验证 C3b 导出的合成 wire；另加未知附件大小、错误占位、32 位无符号 UID 上限和秘密描述测试。fixture 不含真实邮件、密码或 token。
- `mac/FeishuChat/Services/BackendClient+Mail.swift`、`BackendClient.swift`：全部 typed API、路径组件/查询编码、35 秒请求期限和独立安全错误边界。
- `Services/MailKeychain.swift`：精确 UUID 的 file-based SecItem、注入系统调用、分类错误、update-first 写入和幂等删除。
- `Model/MailState.swift`：账号/世代/请求防护、配置与恢复状态机、非秘密持久待删列表、D2/E 接入接口。
- `Model/AppState.swift`、`MessagesState.swift`：单条 SSE 同步按序分派，独立合并恢复任务、能力探测、整箱 badge、旧路由精确清理，真实选择和通知路由分离。
- `Services/BackendSupervisor.swift`：暴露外部后端模式；重新检测由 AppState 停止/重新启动 supervisor，确实重新检测后端能力。
- `Services/NotificationService.swift`：仅新增可注入 badge writer，使实际 AppState 测试不写真实 Dock；生产默认行为沿用。
- `UI/EmailWorkspace.swift`、`RootView.swift`：原生配置/状态、试连只读提示、错误重试、确认移除、旧后端安装命令与重新检测；共享原有安装命令展示。
- `mac/Tests/FeishuChatStateTests/MailIntegrationTests.swift`、`MailKeychainTests.swift`：URLProtocol、假 Keychain、独立 UserDefaults、窗口/badge recorder，通过生产状态/分派入口验证行为。
- 根/mac `AGENTS.md`、`README.md`、`kb/docs/email-foundation.md`、`module-shell.md`、原计划：更新准确实现与未验边界；原计划完整 D/E 验收项仍未勾选，仅增加有证据的 D1 自动子项。

## 实际接口与错误契约

Core 仅依赖 Foundation，不引入 AppKit、Security 或 WebKit。Unix 时间保留为 Int 秒，展示时转换 Date；id/cursor 原样传递，Swift 不重编后端标识。模型包括 account/key/address/attachment/body part/summary/folder/page/body/notification/status/event/account change/test/read result；字段使用显式 snake_case CodingKeys。

App `BackendClient` 的生产入口如下：

| 方法 | HTTP / 用途 |
|---|---|
| `mailStatus()` | GET `/mail/status` |
| `testMailAccount(address:password:)` | POST `/mail/account/test`，不保存配置 |
| `configureMailAccount(address:password:)` | PUT `/mail/account`，读取 UUID 与 removed_account_id |
| `injectMailCredential(accountID:password:)` | PUT `/mail/account/credential`，不重置水位 |
| `removeMailAccount()` | DELETE `/mail/account` |
| `mailFolders()` | GET `/mail/folders` |
| `mailMessages(folder:cursor:)` | GET `/mail/messages`，默认 INBOX |
| `mailBody(id:)` | GET `/mail/messages/{id}`，无已读副作用 |
| `readMail(id:)` | POST `/mail/messages/{id}/read`，D1 不调用 |
| `syncMail(reconnect:wait:)` | POST `/mail/sync`，默认 false/false，UI 同步不等待完整对账 |
| `ackMail(_:)` | POST `/mail/notifications/ack`，整批 id/账号/UIDVALIDITY；D1 不调用 |

请求 body 的密码封装为 MailSecret，仅编码或钥匙串存取时显式提取；描述/反射脱敏，MailState 反射不展开输入和内存秘密。密码不写 UserDefaults/磁盘配置/日志/错误，raw 服务端响应和原始 URLSession 异常不向产品文案透传。邮件错误使用 allowlist code，未知 code 脱敏，401 是本机 token 错误，403 邮箱认证错误不触发聊天登出；聊天仍仅 409 detail=logged_out 进入原登出语义。

邮件请求 timeoutInterval 为 35 秒，留出后端 30 秒等待及约 1.5 秒清理。504 或传输失败重新 GET 邮箱状态，不把超时等同“配置未保存”或“STORE 未发生”。配置/移除超时后，只有新快照/SSE 已确认身份改变才清理先前 UUID；不猜测尚未确认的移除。超时恢复不宣称密码已经写入钥匙串。D2 的 read 超时处理须同样重新核实状态与目标。

## 凭证状态机与持久清理

1. 后端生命周期变更增加 epoch，废弃旧请求/操作，能力重置 unknown，SSE 未连接，generation 基线归零；已有计数保持并标过期。unknown/unsupported 不发邮箱 API，也不读钥匙串。
2. `/status.features` 包含 mail 后读取邮箱快照。自管后端在每次 App 生命周期对每账号自动读一次钥匙串；找到后仅留 App 内存。外部后端模式不自动读或注入，配置页仍允许手动输入。
3. 自管后端 ready、当前 SSE 已连接、状态 credential_missing、有内存密码且未被拒绝时才注入。await 前登记该后端/账号的一次注入，重连/重复快照幂等。后端重启复用内存而不再次读取钥匙串；generation 仅本进程有效，不能跨重启比较。
4. 无条目、用户拒绝/认证失败、锁定/不可交互、其他错误分别提示，提供显式重读；后台不忙重试。auth_failed 保留计数、等待密码更新，不反复注入已拒绝密码。
5. 试连只显示 writable / 只读限制，不保存。保存或更新密码先等待后端成功，首次取得真实 UUID 后写对应钥匙串；configure 后呈 connecting，不能宣称 online。同账号重新保存在状态刷新失败时保留未读数、最后同步及 pending，新账号清零。
6. 写失败保留内存密码和可重试状态，SecureField 清空，界面明确“本次可继续同步，但密码只留在内存；退出 App 后需要重新输入。”不持久化该密码，也不声称已安全保存。重建 MailState 无法凭空恢复该内存秘密，测试覆盖重新输入提示状态。
7. 正常更换/移除使用 returned removed_account_id 清理旧内存、选择/滚动/正文状态及匹配通知待跳转路由；E 的账号清理 hook 已留下。先将准确旧 UUID 写入 `mail-keychain-pending-deletions` 再删除，成功后从列表移除。失败跨状态重建保留，显式重试逐 id 删除；持久内容只有非秘密 UUID，不含密码。重建/再次重建行为测试覆盖失败保留和成功去记录。

SecItem 的 service 固定 `com.reorx.FeishuChat.mail`，account 是 UUID，地址只作为 comment 附加属性；不设置 kSecUseDataProtectionKeychain、access group 或 synchronizable。更新失败不先删除已有密码，只有 errSecItemNotFound 才 add；删除 missing 幂等。OSStatus 分类由注入包装验证。errSecInteractionNotAllowed/errSecNotAvailable 并不精确证明某一钥匙串已锁定，文案也包含“暂时无法交互”；真实系统授权结果留独立验收。

## SSE 顺序、有界恢复与取消

生产 `AppState.consumeEventStream` 不等待每领域 HTTP，直接同步调用 `receiveStreamEvent`；聊天保持原到达顺序，邮件立即应用账号/世代快照和事件。HTTP 恢复分别合并到一个 mailWork、一个 chatWork，布尔需求位记录下一轮，不为每个 SSE 建立 Task；这里的“最多两个”指领域恢复工作，不包括唯一 SSE 读取任务、URLSession 内部工作或用户按钮操作。

mail.updated 即使没有 status 也推进 generation 基线，因此随后较旧快照不能覆盖；已退役账号的更大 generation 也被拒绝。GET 快照捕获 revision，期间已收到 SSE 就丢弃迟到结果；聊天状态 GET 同样检查其 revision。后端更换取消唯一 SSE 与两领域工作，epoch 检查阻止旧任务清空新任务或回写旧状态。

实际调用点测试包括：挂起 `/mail/status` 时 500 条 mail.status 突发、账号切换和迟到旧账号状态；生产消费入口注入连续 300 条 mail.status、300 条 mail.updated、600 条交替聊天状态，再结束流。断言全部邮件 generation 顺序、最终计数/世代、聊天最终顺序结果、恢复任务数不超过两个、mail status 请求合并不超过两次；释放旧 HTTP 后仍不能回滚新状态，工作任务最终归零。测试验证确定性暂停的慢请求，不冒充真实网络吞吐测量。

## D2 / E 接续

- `AppState.mail` 为常驻 MailState；配置视图离开不停止同步。`connection.client` 由外壳统一提供，不新建第二条 SSE。
- D2 可使用 `selectedMessageID`、`selectedFolderID`、`listScrollAnchor`、`detailScrollAnchors`、`bodyLoadState`。账号更换/移除、reset、所选 id 删除会清选择。列表/正文/分页尚未实现；D2 必须继续用账号、epoch、UIDVALIDITY、generation 与当前选择校验迟到加载。
- `selectedRoute` 才是真实选择；`AppState.pendingMailRoute` 只表示待跳转，D1 查看上下文不把它当正文已显示。D2 接通成功正文可见性及 read 前不能仅凭 route 自动已读。
- `onUnreadCountChange` 已接唯一 `AppState.updateUnread`，离线/auth_failed 不归零；新账号/移除归零。`pending` 保留完整批次，D1 不 read、不 ack、不投递邮件通知。
- E 接 `onEvent` 与 `onAccountRemoved`，后者当前由 AppState 清匹配 pending route；新增处理应保留/串联这个清理，按账号命名空间移除系统通知。投递/可见抑制完成后才能 ack，不能因为收到 status/event 就确认。
- 新阅读刷新/通知工作继续采用合并任务，不能重新引入每事件异步任务或阻塞唯一 SSE 的 HTTP await；睡眠唤醒完整联动仍属 E。

## 自动验证与红绿证据

证据目录：`tmp/2026-10-13-email-configuration-d1/`（gitignore，保留供协调审阅）。

| 证据 | 结果 |
|---|---|
| `tests-red.log` | 先写模型/实际状态行为，缺实现时失败 |
| `tests-races-runtime-red.log` | 复现 mail.updated 世代之后较旧快照仍覆盖状态，修正基线 |
| `tests-bounded-red.log` / `tests-bounded-green.log` | 有界恢复调用测试先失败再通过；替换中途的每事件任务设计 |
| `tests-snapshot-red.log` | 同账号重保存遇 GET 失败时丢失计数/最后同步；修正为保留快照 |
| `tests-timeout-cleanup-red.log` | 更换账号已提交但 configure 超时，旧钥匙串清理遗漏；修正为状态确认后清理 |
| `tests-final.log` | 最终 make test：Core 70 项、App 26 项通过；参数化 OSStatus/凭证异常另有多组输入 |
| `build-final.log` | 最终 make build：Debug Build Succeeded |
| `cleanup-sim.log` / `cleanup-browser.log` | mac-dev-cleanup 定向 dry-run，均 nothing to clean |
| `cleanup-preferences.log` | 清除 44 个本阶段 `d1-mail-test-*` 假偏好残留，剩余 0 |

覆盖真实 MailState/BackendClient/AppState 调用：ready/SSE 两者必须齐备、只读一次/重启内存注入、未知/旧后端/外部模式、凭证三类失败和显式重试、重复保存、晚到试连/旧后端请求、账号更换、写/删失败、跨重建持久清理、内存秘密无法跨 App 重建、独立聊天登出、整箱 badge/pending、无提前 read/ack、超时恢复和共享 SSE 顺序/有界工作。SecItem 包装用假系统操作验证 query 精确 id、没有 data-protection flag、写失败不删原条目及安全错误。

最初 wire 测试把 C3b 无附件样本误当含附件，已修正期望并另加附件样本；中途两处测试宏/缺字段错误已修正，这些测试编写问题不作为产品缺陷。没有改后端，未重复跑真实 IMAP 探路或后端 pytest；C3b 的 297 项证据是既有基线，不记作本次测试。不跑 formatter/style linter。

## 清理结果

未启动模拟器、agent-browser、App 或自建监听服务，未注册通知授权，未访问/创建真实钥匙串条目；mac-dev-cleanup 的 sim/browser 定向检查均无资源，不处理用户资源。测试挂起 HTTP 回调已释放、消费流结束、恢复任务归零，测试进程退出。假 UserDefaults 用独立 UUID suite，每测试 defer 清域并同步；早期测试遗留 44 个本阶段域已精确删除，剩余 0。只保留 gitignore 的日志/脚本及正常构建产物，不 make clean，不清用户缓存。

## 自主决策与注意事项

- 沿用原生 NavigationSplitView/Form 和现有安装引导，未改变签名、bundle id 或扩展通用 IMAP 主机配置；按 SwiftUI/impeccable/kb 技能实施，实机审阅留独立验收。
- 不把旧后端当普通网络错误；未知能力不能提前访问钥匙串。重新检测要实际重启自管 supervisor，外部模式需先由用户升级外部服务。
- 待删除记录持久化非秘密 UUID；未保存密码只留内存。恢复工作采用每领域单任务合并，避免 SSE 事件量变成任务数量。
- 独立自动测试只使用隔离 UserDefaults suite，不访问用户正式偏好、邮件账号、系统 SecItem 或 Dock，生产默认系统行为保持；不可据此宣称真实授权/UI 已通过。
- 新阶段的有意未实现项不登记为 known issue；没有新增确认的范围外产品缺陷，也没有更改 known-issues/next-up。

## 交给协调者

- D1 可审阅自动实现与交接接口；配置 UI、窄窗口/最小窗口、键盘/切换状态和真实 SecItem 分类仍未验，本 tab 未启动实机验收。请由独立验收阶段安排。
- 实测 Debug/Release 对对方创建的测试 UUID 条目是否弹授权框后，再决定是否按构建分 service；当前未有证据需要分离，不提前修改签名或命名策略。测试条目必须隔离并在验收后清理。
- D2 继续实现文件夹/列表/分页/正文安全 WebKit/成功可见已读，E 完成通知投递、精确账号清理、pending/ack、睡眠唤醒与完整聊天回归；本次只提供接口，未开始这些工作。
- 真实邮箱 Seen 持久化、跨端 flags、在线通知、实际 Dock 和睡眠恢复沿原计划 F 待验；没有需要用户现在决定的事项。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 完整阅读并遵守当前 D1 brief，只读未修改。
- [邮箱阅读器计划](../plans/2026-10-13-email-reader-plan.md) — 开发依据，更新 D1 自动子项，完整 UI/真实验收保持待办。
- [B 实现](2026-10-13-email-shell-phase-b.md)、[B 独立验收](2026-10-13-email-shell-b-acceptance.md) — 外壳及实际接续入口。
- [C3a](2026-10-13-email-sync-c3a.md)、[C3b](2026-10-13-email-api-c3b.md) — 服务/HTTP/SSE/重启/确认契约与合成样本。
- [模块外壳](../docs/module-shell.md)、[邮件基础](../docs/email-foundation.md) — 本次同步更新。
