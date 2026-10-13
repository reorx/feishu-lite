---
created: 2026-10-14
tags:
  - email
  - reader
  - security
  - acceptance
---

# 邮箱 D2：收件箱阅读器、安全正文与可见性已读

## 概要

在当前 master、D1 `bf490b8` 和协调 brief `1aa3396` 上完成 D2：收件箱列表、100/50 分页、全部文件夹菜单、原生详情/纯文本/HTML/附件元数据、按渲染证据及 ViewingContext 提交已读。保留 D1 配置与凭证恢复，页外路由增加最小缓存摘要接口，提供 E 可调用的加载入口。后端 301 项、Core 72 项、App 46 项测试与 Debug 构建通过。工作跨到 10 月 14 日，报告及证据路径遵守 brief 使用 10 月 13 日。

本 tab 未启动实机 UI、App、浏览器或模拟器，未读取真实 env/邮箱/缓存，未访问真实钥匙串或改真实 flags，未 make run、改变签名/bundle id、push/发布、开始 E 或委派。协调文档只读。实际 WebKit 安全和 UI 证据留独立验收，不能以自动策略测试替代。

## 修改的文件

- `mac/FeishuChat/Model/MailState.swift`、`MailState+Reader.swift`：复用唯一 MailState，常驻列表/选择/滚动状态，身份与请求代次、合并刷新、渲染证明和已读去重。
- `mac/FeishuChat/Model/AppState.swift`：统一 ViewingContext 使用已显示正文目标；既有模块/激活/窗口入口补判邮件，SSE 重连补列表恢复，提供 pending 路由加载方法。
- `mac/FeishuChat/Services/BackendClient+Mail.swift`：typed 按 id 摘要调用。
- `mac/FeishuChat/Services/MailHTMLLoadGate.swift`、`MailHTMLController.swift`：生产首载保护门、公开 WK 配置/规则、两 delegate 的导航策略和 interactionState。
- `mac/FeishuChat/UI/EmailWorkspace.swift`、`MailInboxList.swift`、`MailMessageDetail.swift`：原生双栏、全部文件夹菜单、状态与配置入口、摘要、正文、附件信息及滚动恢复。
- `mac/FeishuChatCore/Sources/FeishuChatCore/MailHTMLPolicy.swift`：纯 Foundation 的 CSP 文档、block-all 规则和 HTTP(S) 用户链接检查，无 AppKit/WebKit 依赖。
- `backend/src/feishu_lite/mail/api.py`、`service.py`：鉴权的精确缓存摘要读取，沿用现有 MailSummary 和身份错误。
- `backend/tests/mail/test_reader_api.py`、`mac/Tests/FeishuChatStateTests/MailReaderTests.swift`、`MailHTMLGateTests.swift`、`mac/FeishuChatCore/Tests/FeishuChatCoreTests/MailHTMLTests.swift`：先红后绿行为与回归。
- 根/mac AGENTS、根/backend README、邮件基础/模块文档、原计划和 known-issues/next-up：同步已完成的自动范围和未验事项；实现及总结同次提交。
- 本报告；临时合成样本/脚本/日志均在 gitignored `tmp/2026-10-13-email-reader-d2/`，不入库。

## 生产接口与 E 接续

原 C3b wire 不变。列表仍是 `GET /mail/messages` 首次默认 100、带 opaque cursor 后默认 50，正文 `GET /mail/messages/{id}` 返回 `{kind,content}`，正文 GET 不写 Seen；附件信息来自摘要。App 不按 Date 重排，按完整 id 去重后 UID 倒序；整箱 badge 来自 MailStatus.unread_count，不等于页内未读行数。

D1/C3b 原接口仅能从列表取得头部元数据，按 id 正文没有摘要；页外通知目标不能靠正文构造发件人/附件，也不能为定位扫描整箱。已先向用户报告该限制，D2 增加：

| 接口 | 契约 |
| --- | --- |
| `GET /mail/messages/{id}/summary` | Authorization Bearer launch token；返回列表 items 相同的完整 MailSummary，不加新 schema；只读当前缓存，不联网、不取正文、不 STORE |
| 错误 | 缺/错 token 401；非 INBOX、畸形 id 400；缓存缺失/已删 404；旧账号/UIDVALIDITY 410；均沿用安全 mail code |

`MailService.summary()` 在事件循环线程复用 `_key()` 的完整身份/缓存校验；Swift `BackendClient.mailSummary(id:)` 仍使用编码后的单路径组件和原邮件错误/超时规则。没有新依赖或数据库迁移。

E 可以调用 `await mail.openRoute(.email(accountID:…,folderID:"INBOX",messageID:…))`，或在能力及账号恢复后调用 `await app.loadPendingMailRoute()`。前者关配置页、选择 INBOX，目标在页内直接用摘要，否则精确 summary GET 后 body GET；汇总 nil id 回到列表。旧账号/文件夹/404/410 回收件箱并提示，不会按裸 UID 找另一封。后者只在当前 pending 仍等于原路由时清 pending，再补判显示；当前没有自动调用它。

`pendingMailRoute` 是跳转意图，`selectedRoute` 是选择，`displayedBodyRoute` 才是当前渲染成功的证明；App 的 ViewingContext.selectedMail 使用最后一个。E 应继续通过统一 ViewingContext 决定抑制。D2 没有投递通知、调用 ack、添加唤醒逻辑或清理已递送邮件通知；pending/批次与 onEvent/onAccountRemoved 契约沿用 D1/C3b。

## 注意事项：异步、显示与已读

身份包含后端 epoch、账号 UUID、连接 generation、UIDVALIDITY 和完整邮件 id；选择 revision 与独立 presentation UUID 再约束渲染回调。无 status 的 mail.updated 同样先推进 readerGeneration、失效旧请求，防止旧正文在连接代次已变时进入 loaded。换账号、UIDVALIDITY reset、删除当前目标清选择及渲染证明；旧响应不覆盖当前状态。

后台事件只置一个 readerTask 的合并标志，不等待 HTTP、不创建每事件任务。显式刷新也加入同一任务，避免两个刷新入口相互等待或空转。慢请求期间重复刷新立即失效旧分页，当前任务结束后至多合并下一轮；分页游标/revision/身份全部一致才合入。刷新从首页重建已加载 UID 前缀直到原最早 UID 边界，去除掉线期间删除的条目，也避免新信挤掉用户已经加载的最早页；不下载全箱正文。旧 cursor 410 丢弃游标、核实 status 后重取前缀；普通失败保留旧列表与计数，首次 not_synced 不称空箱。

视图先出现但尚无账号/UIDVALIDITY 时不发无身份请求；第一份有效账号状态到达后，apply(status) 自动排入同一个列表任务。后端重启后的 readerGeneration 从零恢复也会触发，避免依赖用户手动刷新。

纯文本用原生 Text(verbatim:) 展示，当前视图 task 出现并恢复锚点后才 bodyDidDisplay；HTML 只在该 WKNavigation 的 didFinish 时确认。规则编译失败、加载失败、进程终止和旧 WK 回调都不能确认。配置页、离开/重建正文、切目标及连接变化撤销证明。纯文本加载完成本身、HTTP 200、pending 路由、列表/预取和后台刷新均不能提交 read。

`AppState.reevaluateViewing()` 及既有模块/激活/key 入口同时补判两领域。mail 必须在线、当前正文已显示、Email/前台/窗口可见、当前摘要仍未读才 POST read；真正发 wire 前再核对。每身份自动尝试一次，失败保留未读/全箱 count，提供显式按钮，不排离线写队列。504/transport/404/410 失败只刷新 status 并精确核实摘要一次：已 Seen 修正当前行，缺失回收件箱，未读保留错误，不自动循环。切走后返回未确认的请求也显示显式重试入口；取消 HTTP 不等于撤回已发 STORE。成功 read 更新接口确认的 read_ids，整箱计数随后从 status 取，仍走唯一 updateUnread badge 入口。

**离线恢复与不确定 STORE 的边界**：仅离线阅读缓存正文没有发送 POST，也没有写入 readAttempts；恢复 online 时 apply(status) 自己 reevaluateViewing，当前成功显示目标仍满足 ViewingContext 就自动补 read 一次，同 generation 也如此，无需手动操作。已经发送 POST 且失败/超时或离开导致结果未确认时，保留该身份的尝试记录；先核实 status/目标，仍未确认才显示显式重试，不能因同 generation offline→online 再自动 STORE。协调者要求的两种情形分别由生产 refreshStatus→apply 调用链测试，未加人为 reevaluate 掩盖入口遗漏。

模块重建保留列表首可见 id、纯文本首可见段落 id；HTML 使用公开 macOS WKWebView.interactionState 保存滚动等交互状态，不用私有 scrollView、页面 JS 或脚本桥。只恢复相同完整身份和正文的内存状态，不写磁盘；旧账号/UIDVALIDITY 清除。恢复实际落点和最小 800×460 布局尚未验。

## 注意事项：HTML 隔离

每封独立 WKWebView 使用 nonPersistent 数据存储、allowsContentJavaScript=false、禁止 JS 自动开窗口和空 WKUserContentController。没有本机 token、脚本消息桥、其他账号或聊天数据注入。严格 CSP 的 default/script/connect/img/media/font/frame/object/base/form 均 none，只有随机 UUID nonce 授权 App 排版样式；后端正文继续按当前净化规则处理。

`MailHTMLLoadGate` 的 prepare 调用编译 block-all `url-filter:.*` 规则并挂到当前 controller，成功后才 loadHTMLString；失败不加载并提供正文重试，拆视图时规则保留至销毁。navigation delegate 只放行首个内部 about:blank 文档；拒绝自动导航、表单、iframe、file/data/javascript/custom。只有 linkActivated 且显式有效 host 的 HTTP(S) 可外开，允许合法内网/IP；普通点击 NSWorkspace.open 后取消 WK 导航，_blank 通过 WKUIDelegate 外开并返回 nil，不创建新 WK。无链接预览或远程图片开关。

策略依据公开 SDK headers；macOS 公开 interactionState 可用，而 scrollView 为 iOS API。block action 未指定 resource-type 时匹配全部资源，参考 [WebKit 官方 Content Blockers](https://webkit.org/blog/3476/content-blockers-first-look/)。这些实现与策略测试不能证明真实 WK 在本机执行/网络行为，必须完成下方独立验收。

## 自动验证与红绿证据

证据根目录：`tmp/2026-10-13-email-reader-d2/`。所有请求和邮箱内容为合成，URLProtocol、fake credentials、独立 UserDefaults suite 或测试自身 loopback HTTP/IMAP；没有实机 UI 截图。

| 验证 | 结果与日志 |
| --- | --- |
| 后端先红 | `backend-red.log`：summary 路由未实现时 2 failed / 2 passed |
| 后端最小绿 | `backend-summary-green.log`：4 passed，包含参数化鉴权、页外/离线、零额外 IMAP、旧身份/文件夹/删除/畸形 id |
| 后端全量 | `cd backend && uv run pytest`，301 passed / 48.72 秒；`backend-first-full.log` |
| Swift 初始红 | `app-red.log`、`tests-red.log`：新增生产阅读/策略接口不存在；随后 `app-runtime-first.log` 运行通过第一批阅读行为 |
| 刷新空转复现 | `tests-second-full.log` 与 `app-hang.sample.txt`：手动刷新期间合并任务在 main actor 空转；终止自建测试进程，统一任务入口，新增 queuedRefreshDuringDirectRefresh 测试；后续全量通过 |
| 前缀/代次红 | `prefix-red.log`：插入新信丢原最早已加载 UID；`generation-red.log`：无 status 更新后旧正文仍可 loaded；修复后对应测试通过 |
| 中断已读红 | `interrupted-read-red.log`：返回正文无可重试错误；保留去重且补明确提示，最终回归通过 |
| 首次身份红 | `initial-status-red.log`：第一份账号状态到达仍未载入列表；apply 自动排入合并任务，最终回归通过 |
| Swift 全量 | `cd mac && make test`：Core 72 / App 46 全通过；`tests-final.log`，新增 Core 2、App 阅读 17/HTML门 3，D1/模块/聊天回归全部保留 |
| Debug 构建 | `cd mac && make build`：Build Succeeded；`build-final.log`，没有改签名或配置 |
| 合成验收工具 | `uv run --project backend python tmp/2026-10-13-email-reader-d2/safety_fixture.py --check`：仅合成 HTTP 冒烟通过，关闭 listener/thread；`fixture-smoke.log`。这不是 WebKit 零请求证据 |

App 自动行为覆盖不透明游标、分页/刷新交错、持续事件有界工作、首次身份后自动加载、UID 顺序/去重/整箱 badge、保持原最早前缀、当前成功显示后 read 一次、模块/后台/隐藏窗口不 read、快切邮件/账号与旧渲染 token、离线缓存和未缓存正文、同 generation offline→online 自动补 read、失败 read/显式重试/504核实及不确定 STORE 恢复后不自动重复、旧 cursor/删除、页外目标、无 status 连接代次及中断读返回。actualAppReevaluate 测试直接使用 AppState 模块 didSet/reevaluate 与无窗口 recorder，不启动 App；验证 HTTP 成功尚无 displayed route。

HTML 自动测试调用生产 gate、配置和两 delegate 共用 router：保护未就绪不首载、编译失败封闭、退出后迟到编译不加载、JS禁用/nonPersistent/空user scripts、普通/_blank 用户HTTP允许及自动/其他scheme拒绝。未实例化实际可见 WKWebView、未跑 JS/资源计数或真实默认浏览器，不能当这些方面的验收。

## 交给协调者：独立 UI/WebKit 与范围外事项

1. 另派独立验收；先遵守桌面测试文档/context 检查，使用只读不到真实邮箱/钥匙串的隔离 HOME 与外部合成后端。`safety_fixture.py --serve --port 18874` 可复用：固定 synthetic token `synthetic-d2-only`，合成账号 UUID 以 d2 结尾，160 封 UID、100/50 页、中文/不可选文件夹、长正文/附件、有限 SSE。脚本默认只导出不监听，--check 也已关闭服务；当前无 listener。
2. `adversarial.html` 是绕过后端净化直接送给 App 的攻击样本，`sanitized.html` 是同源净化版本，`synthetic-wire.json` 可复用。检查 App 第一封、第二封、切回时 `/control` 的 resources 是否均零：JS/handler、远程/CID/file 图片、CSS URL、stylesheet、iframe/object、meta跳转、form；JS 标记 SCRIPT EXECUTED 不应出现，文字可读。纯文本的 `<script>literal</script>` 必须原样显示。无用户链接点击时 probe 零才有效；点击普通/_blank 后默认浏览器可以请求 user-normal/user-blank，应单独计数，不能混进自动资源指标。
3. 实测用户 HTTP(S)/内网/IP 外开及 _blank，不允许自动或其他scheme；需要带保护编译失败/延迟的测试注入时只能在隔离 harness 构建，不改变正式应用安全门。确认 failure UI 没显示未保护内容，并能重试。
4. 验证 800×460、调整列宽、深浅色、长中文主题/地址、空值、附件未知/约数、目录标识、分页/刷新/删除、两栏及配置返回；阅读器列表/纯文本/HTML 首可见位置切模块后恢复，Email 回车不发聊天、草稿和聊天未读保持。截图归档 tmp 对应独立验收目录。
5. 用合成 HTTP read 计数验证真实前台/后台/窗口关闭/切模块、慢/失败正文和切目标：加载不read、成功显示当前目标才read、返回前台补判一次、旧WK不read新目标。fixture read 仅修改内存 SEEN，不触碰 IMAP；实际系统通知、投递/ack/唤醒和精确通知清理留 E。
6. D1 真实 SecItem/Debug-Release 互访与配置 UI 仍待独立验收；真实跨端 Seen、断网/睡眠和 F 测试新信需用户指定邮件/来源，不能使用工作邮件。没有发现需用户决定的产品范围变更，当前不等待确认。

## 遗留问题与自主决策

- 实际 WebKit 安全与 UI 未验，登记 known-issues；独立验收条件登记 next-up。自动验证范围已完成，没有已知未修的测试失败。
- 页外元数据采用最小同步缓存摘要 GET，避免改正文 wire、伪造头部或全箱扫描；新增端点不增加 feature 名，旧 mail 后端缺此端点会安全返回页外目标不存在，E 使用时应配套更新后端。
- 采用已加载 UID 边界重取前缀，可能为大量新信多取几页摘要，保证原旧页不丢；不抓正文或整个邮箱。合并刷新与状态恢复独立有界，不占 SSE 消费。
- HTML 滚动用公开 interactionState；纯文本按段落锚点恢复，不承诺段落内部像素位置。是否需要更精细恢复由独立验收结果决定，当前不扩展到附件下载、其他文件夹或发送/回复。
- 原计划新增 D2 自动完成条目，完整 D/UI/WebKit 实测项保持未勾选，协调文档未修改。

## 清理

测试持有的 HTTP、URLSession 回调和 reader/read任务在测试 teardown 结束，合成 smoke listener/server/thread 全部关闭；本阶段曾挂起的自建 swiftpm-testing-helper PID 9902 已终止并保存 sample。最终 pgrep 无 swiftpm-testing-helper、xcodebuild 或 safety_fixture.py 残留。D2 UserDefaults suites 使用 UUID，defer 删除测试 domain；credentials 为 fake，无测试钥匙串条目。

运行 `mac-dev-cleanup --only browser --min-age 2` 与 `mac-dev-cleanup --only sim`，均 nothing to clean，见 `cleanup-browser.log` / `cleanup-sim.log`。保留 gitignored 合成样本和构建/测试日志供独立验收；没有启动实机 UI，因此无截图需要归档。

## 相关文档

- [协调任务](../plans/2026-10-13-email-reader-coordination.md) — 完整读取，D2 范围/完成条件依据，只读。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 读取全文并更新有证据的 D2 自动条目。
- [B 实现](2026-10-13-email-shell-phase-b.md) / [B 验收](2026-10-13-email-shell-b-acceptance.md) — 保留模块、草稿、键盘及滚动契约。
- [C3b](2026-10-13-email-api-c3b.md) / [D1](2026-10-13-email-configuration-d1.md) — wire、错误、恢复、凭证、有界任务及通知接续依据。
- [邮件基础](../docs/email-foundation.md) / [模块外壳](../docs/module-shell.md) — 更新当前显示、已读、安全与 E 边界。
- [已知问题](../known-issues.md) / [后续检查](../next-up.md) — 当前独立验收缺口与触发条件。
