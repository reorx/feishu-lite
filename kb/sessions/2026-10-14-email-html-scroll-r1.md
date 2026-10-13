---
created: 2026-10-14
tags:
  - email
  - webkit
  - scroll
  - repair
---

# HTML 阅读位置 R1：修复会话恢复导航与拆除时的位置保存

## 概要

在当前 master、协调 brief `7c870df` 上完成 R1 自动交付。完整读取协调文档、原计划、根/mac AGENTS、D2/F1 报告与模块/邮件基础文档，并实际查看 F1 的 `03-html-scroll-before.png`、`04-html-scroll-restored.png`：同一 HTML 邮件由段落008回到页顶，缺陷成立。没有将截图失败忽略为工具问题，也没有将81的归因不足登记为第二个产品缺陷。

先写生产 controller 生命周期失败测试，再修复：HTML 使用可重新供应当前正文的内存文档 URL，规则挂载后直接恢复 WK 会话；跟踪恢复产生的新 navigation，完成后才提供显示证明。切另一封再拆旧视图也能保存旧目标的位置，缓存所有权防止旧构造/旧保存覆盖新展示。最终 `make test` Core74/App81 全通过，Debug `make build` 成功。

本 tab **只做自动交付**。无窗口 WK 测试证实恢复导航和正文重建可用，不能证明实际像素/首可见段落落点；known-issues 保留“修复待独立复验”，F1/F 不标通过。没有开 App 窗口、实机验收、下一阶段或委派；未读真实 env/邮箱/缓存/钥匙串，未运行 make run、改正式 bundle/signature、发消息、push/发布或建立分支/worktree。

## 根因与方案依据

旧实现先 `loadHTMLString`，在其 `didFinish` 内设置 `interactionState`，随后立即认定显示成功。公开 interactionState 实际保存/恢复的是会话，不是只设置滚动偏移；设置器会启动恢复导航。旧 router 已消耗唯一初载许可，后续恢复导航无法获得许可；而关于 about:blank 的历史也不能重新供应原先通过 loadHTMLString 注入的正文。旧代码既没有接续恢复导航，也在它完成前提供了显示证明。

依据：[Apple 公开 interactionState](https://developer.apple.com/documentation/webkit/wkwebview/interactionstate)、[WebKit 公开实现 WKWebView.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm) 的 interactionState getter/setter。后者调用会话恢复并开启导航；这里只用于解释公开 API 语义，产品没有调用私有 API 或解析其私有数据格式。网页检索先尝试 firecrawl（无结果），再查官方资料。

另一个确定的保存缺口：selectMessage 先改选择，SwiftUI 随后 dismantle 旧 WK；旧 stop 要求 selectedMessageID 仍是旧目标，因此切另一封会漏存。现在校验账号/UIDVALIDITY/epoch/generation 和 cache owner，不要求当前仍选旧邮件。旧控制器的 stop 不能撤销新 render token，迟到构造也不能抢占新 owner。

## 精确隔离范围

- scheme：`feishu-mail-body`；单个文档为 `feishu-mail-body://document/<随机 UUID>`。UUID 仅是内存文档身份，不含邮件账号/id/token。每个 WK 的 handler 只供应此**完整 URL**对应的当前 CSP 包装正文，其他 URL 返回 resourceUnavailable；不访问磁盘、网络、IMAP、本机后端或其他邮件。
- 内容规则首先 block `.*`。唯一 `ignore-previous-rules` 例外的正则为 `^<转义后的完整文档 URL>$`，只匹配 `resource-type: [document]`。其他同 scheme URL、路径后缀、query/fragment、HTTP/file URL及图片/样式等资源不能借此例外获准。
- 内容规则的 document 类型本身包含 frame 文档，**规则例外单独并不区分主框架**。主框架边界由 CSP `frame-src 'none'` 和 production navigation delegate 独立落实：只允许第一次、非用户点击、主框架、非新窗口、URL精确匹配的当前文档导航；iframe、自动后续导航和所有 scheme 用户点击（含_blank）拒绝。不可把“document例外”单独描述成足够的安全条件。
- nonPersistent、allowsContentJavaScript=false、禁脚本自动新窗口、空用户脚本、原 CSP 的资源/file/CID/连接/表单隔离继续使用。普通和_blank合法 HTTP(S) 用户点击仍走原两delegate router 外开，没有放宽自动 HTTP(S) 或增加页面 JS。
- `MailHTMLLoadGate.prepare` 编译并挂载**本次完整规则**，之后才供应正文及 load/interactionState 恢复。恢复产生的 didStartProvisionalNavigation 登记该 WKNavigation；didFinish 必须匹配该句柄、未stop且当前token，MailState再核对账号/世代/选择/渲染身份。旧navigation、旧compiler、旧视图均不能提供当前成功显示证据。失败仍封闭并允许既有正文重试。

## 生命周期与资源边界

- 每次工作区重建创建新 WK，不保留隐藏 WKWebView 或完整 DOM来掩盖失败。内存 handler 为新视图重新供应当前正文，使公开会话恢复有可加载的原 URL。
- `MailHTMLInteractionCache` 最近8封，单份 opaque NSData最多256 KiB，缓存 state 总量最多2 MiB，加固定身份、SHA256摘要和URL；正文全文不放入交互缓存。超大 state 不保存，超过8封最旧位置淘汰。对超出此边界的返回，允许从页顶打开；不跨App退出保存。
- 缓存精确匹配 epoch、账号、generation、UIDVALIDITY、完整messageID与正文SHA256；正文/身份变化给新URL和空state。账号/UIDVALIDITY及连接失效清缓存。owner为本次presentation UUID，旧保存或旧构造不能覆盖新owner。
- 当前WK仍需要当前正文与安全包装文档；stop取消gate/loading、停止WK、断开两delegate并清handler.data，blocker保留到WK销毁。缓存不引用controller/WK/正文；没有新后台同步循环或后端/通知改动。
- 取舍：重新供应安全文档比保留WK更容易限制资源和隔离账号；新增的本机scheme及document例外需要独立复验，不能仅引用旧F1的renderer安全结论。

## 自动验证与红绿证据

证据目录：`tmp/2026-10-14-email-reader/r1-scroll/`，全部合成资料。生产测试位于 `mac/Tests/FeishuChatStateTests/MailHTMLScrollTests.swift`，作为同一个serialized MailReaderTests的extension，复用隔离URLProtocol/fake credentials/UserDefaults；避免两suite并行污染同一fixture。

| 检查 | 结果与日志 |
| --- | --- |
| 初始行为红 | `red.log`：2项失败，重建实际调用为load而非restore，换邮件后拆旧controller没有保存旧state；编译运行成功、正常exit1。 |
| 测试工具修正 | 初始spy直接构造WKNavigation导致其析构SIGTRAP；改为通过公开WK load取得真实句柄后重新跑红。该工具错误不记产品缺陷，不使用崩溃替代失败证据。 |
| 初步绿 | `green-initial.log`：两条复现通过。 |
| 真实无窗口WK | `real-wk.log`：生产规则编译/挂载、scheme handler、两delegate加载与恢复，同URL/正文可查找、无多余历史项；没有开窗口或像素断言。首次增加测试曾发现block-all也拦主文档，明确增加上述精确document例外后通过。 |
| 快速构造竞态红 | `red-stale-owner.log`：迟到旧controller抢占新owner，先失败，再拒绝旧token claim；最终全量绿。 |
| 针对性回归 | `targeted.log` / `targeted-final.log`：恢复时机、切另一封保存、规则pending/失败/拆除、旧保存/旧finish、正文和各身份隔离、有界内存、scheme导航及HTTP/_blank。末轮加入owner用例后以全量为最终证据。 |
| 最终全量 | `cd mac && make test`：Core74、App81通过，App测试1.216秒，`tests-final.log`。新增14项，原已读/分页/双模块/通知/凭证自动回归保留；最终还包含切另一封再返回的实际restore调用和query/fragment拒绝候选。 |
| 精确URL补验 | `swift test --filter documentNavigationOnlyAllowsTheExactTopLevelInitialTarget`通过，`precise-url-final.log`；随后再跑上述最终全量，产品代码没有后续改动。 |
| 构建 | `cd mac && make build`：Build Succeeded，`build-final.log`，没有formatter/lint或签名配置修改。 |
| 复验工具 | `recheck-scroll.py`语法编译通过；本tab未运行其GUI步骤，不能作为屏幕通过证据。 |

实际WK隔离用例将未净化的合成HTML送入production renderer，含同scheme其他URL的img/stylesheet/iframe/object与脚本：首载和恢复每次handler只收到精确主文档一次，无其他scheme资源请求，脚本执行标记不可查找。策略测试另覆盖精确URL的子frame/用户点击、同scheme其他URL、其他scheme/自动HTTP拒绝与普通/_blank合法用户HTTP(S)外开。它们支持新的自动隔离边界，不代替下一tab对HTTP/file/CID等原F1完整资源计数的独立复验。

所有新增测试异步等待有期限：reader条件400×5ms（2秒）；真实WK find回调另设2秒超时，超时记录失败并恢复continuation；等待故障注入也有2秒期限，不靠无界continuation/task group等待。手动delegate回放使用真正的WKNavigation句柄，迟到旧句柄在新restore didStart之前/之后均不能标显示。

## 独立复验入口与交给协调者

1. 用最新master源码重新建立隔离App，沿用F1独立bundle/ad-hoc/fake SecItem/外部合成后端办法；**不能使用旧FeishuChat-F1.app验修复**。本tab没有建立或运行GUI副本。先按context/桌面测试约定检查资源及窗口身份。
2. 复用 `tmp/2026-10-14-email-reader/f1-acceptance/fixture.py`，18874确认空闲后再启动，合成token为synthetic-f1-only。初始正常renderer不要注入故障。打开“安全 HTML 160”，窗口980×680，记录read及resource基数。
3. 新AX工具必须指向新隔离bundle。可用 `uv run --project backend python tmp/2026-10-14-email-reader/r1-scroll/recheck-scroll.py --ax <新AX工具绝对路径> --output tmp/2026-10-14-email-reader/r1-reacceptance` 收集滚动750→Messages→Email前后PNG/AX/control。脚本子进程15秒、HTTP3秒期限；只采证，不自动判断像素。必要时按实际viewport改scroll-x/y。独立对比首可见段落与几何位置，不以脚本exit0签收。
4. 加测同HTML切另一封（160→157→160）、快速切模块/目标，确认恢复原段落且read/resource不多增；浅色/拖宽后观察布局重排，纯文本/列表/聊天草稿与Email回车沿用原F1回归。
5. 新renderer必须重验首封/恢复的HTTP/file/CID/样式/frame/脚本自动资源零请求、普通/_blank外开及规则pending/失败封闭；新内存主文档自身是预期供应，不能计为外部资源。F1旧故障注入脚本匹配的是旧无参compileRules，新签名为compileRules(documentURL:)，接续者需调整**隔离副本**注入，保留实际规则门，不将工具匹配失败当产品缺陷。
6. 屏幕落点、真实资源矩阵和剩余F1/F2未验均交协调者另派；本tab不扩大到后端、通知、真实邮箱或系统授权。不登记浅色工具失败、cursor按钮定位失败和81归因不足为新产品缺陷。

## 修改的文件

- `MailHTMLController.swift`：安全门后恢复新会话/导航、精确主文档规则例外与router、旧token/保存保护及测试注入。
- `MailHTMLDocument.swift`：只供应本次精确URL正文的内存handler，停止时清数据。
- `MailHTMLInteractionCache.swift`：有界会话bytes/正文摘要/owner/身份缓存。
- `MailState.swift`、`MailState+Reader.swift`：接入缓存及连接失效清理，其他读取/通知行为不改。
- `MailHTMLScrollTests.swift`：14项自动行为/真实WK/隔离/竞态；`MailReaderTests.swift`仅将两个fixture helper开放给同suite的extension。
- 根/mac AGENTS、README、模块/邮件基础文档、原计划与known-issues/next-up：同步自动修复和独立复验边界；协调文档只读。

## 遗留问题

HTML实际段落/像素落点待下一独立tab复验；F1浅色/拖宽/完整cursor恢复及账号/UIDVALIDITY/连接渲染归因继续保留。F2真实SecItem/系统通知/唤醒/完整聊天回归未开展。当前没有遗留自动测试失败；没有新增范围外产品缺陷。新增scheme例外的完整实机资源回归是此次交给协调者的重点。

## 清理与工作区

所有测试controller在defer/stop中断开delegate并停WK；隔离MailState停止reader，临时UserDefaults domain删除，凭证为fake，没有SecItem条目。无App窗口、后端listener、模拟器、agent-browser或caffeinate由本tab启动。最终无swiftpm-testing-helper/xcodebuild残留，记录`remaining-test-processes.txt`。

执行 `mac-dev-cleanup --only browser --min-age 2`，exit0，nothing to clean；保留1个小于2小时的其他会话浏览器，未清用户/其他tab资源，见`cleanup-browser.log`。tmp脚本、日志保留供接续；没有新增截图，原F1独立截图仍在原归档目录。

代码与以上必要文档同次提交；只暂存本任务文件，当前master，不push。提交后工作区状态在本tab最终摘要回报。

## 相关文档

- [协调brief](../plans/2026-10-13-email-reader-coordination.md) — 完整阅读、只读，R1范围依据。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 同步自动交付，不勾F1/F完整验收。
- [D2交接](2026-10-13-email-reader-d2.md)、[F1独立报告](2026-10-14-email-reader-f1-acceptance.md) — 渲染/已读契约、截图与未验边界。
- [模块外壳](../docs/module-shell.md)、[邮件基础](../docs/email-foundation.md) — 更新资源边界和修复待复验状态。
- [known-issues](../known-issues.md)、[next-up](../next-up.md) — 保留协调复验和范围外既有未验事项。
