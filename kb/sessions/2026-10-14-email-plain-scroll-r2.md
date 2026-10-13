---
created: 2026-10-14
tags:
  - email
  - scroll
  - repair
  - textkit
---

# 纯文本阅读位置 R2：布局后恢复原生只读正文

## 概要

在当前 master 完成 R2 自动交付，开始 HEAD `e3dc732`（协调文档提交，F1b报告 `7281388`，产品仍为R1基线 `f148274`）。完整阅读协调计划及当前R2、原计划、根/mac AGENTS、D2/R1/F1b报告、known-issues与模块/邮件基础文档，实际查看F1b的10/11失败PNG。使用SwiftUI、kb及收尾systools指导。先用无窗口实际SwiftUI宿主复现非顶部位置已经保存、重建后实际偏移仍为0，再修复；9项新回归、Core74/App90及Debug构建通过。

纯文本改为只读、可选择的原生NSTextView/NSScrollView，在有效TextKit布局后恢复文字索引及行内偏移，宽度变化后重新定位同一文字。最近8封位置只存内存，按完整身份/正文摘要隔离。HTML controller、scheme、安全门、导航、会话恢复均无修改；邮件列表、通知、后端与聊天逻辑无修改。

本tab没有启动App窗口、实机验收、F2或其他agent；没有访问真实env/邮箱/缓存/钥匙串、改真实Seen、make run、改正式bundle/signature、创建分支/worktree、push或发布。下列自动证据不能代替独立屏幕验收，known-issues保留“修复待独立复验”，F1/F不签收。

## 根因与证据边界

F1b正常隔离副本中，纯文本159首完整段落026→000，选择/身份/窗口及正文GET/read/资源计数不变。10/11图确实回顶，本次没有把它当作工具定位错误。原截图和AX归档仍是 `tmp/2026-10-14-email-reader/f1b-acceptance/10-plain-before.*`、`11-plain-after.*`。

旧纯文本用LazyVStack/ScrollViewReader；两次Task.yield分别围绕一次scrollTo，然后无条件结束restoring、产生displayed证明。yield只交出任务执行权，不能证明viewport、目标行及滚动布局已就绪；旧代码也没有检查恢复实际到达目标。Preference回调随后可写入任何当前可见行，不验证当前渲染token/正文身份，初始化及退役布局缺少保护。

第二份复现来自真实NSHostingView中的原生产MailPlainBody，未创建NSWindow、未发屏幕事件：合成160段字面文本，原生clip实际滚动750，观察到非顶部段落锚点；创建新render token和宿主，等待displayed并布局，偏移仍为0，保存锚点仍非顶部。失败断言检测的是实际NSScrollView几何，不是只测一个存储变量。`red-view.log`编译成功、正常exit1。因此至少确定旧路径会在没有有效恢复时宣布正文出现，单次scrollTo/yield不足以构成恢复契约。

**仍不能证明的部分**：无窗口宿主与F1b可见窗口环境不同；F1b没有逐帧布局/锚点追踪，不能确定原屏幕失败究竟是未就绪的scrollTo还是后续临时顶部写入，也不能从本次推断每次实机会失败。原F1通过与F1b失败的触发差异未知，不编造为HTML、账号、网络或已读变化。尝试原生SwiftUI scrollPosition的无窗口探路也未得到有效恢复，记录在native-*.log；这不证明该API在正常窗口中普遍失效。

采用直接管理原生文本布局与滚动的方案，消除对任务调度/虚拟段落实现时序的依赖，使生命周期和文字位置能在无窗口环境重复检验；真正屏幕落点由下一独立tab判定。

## 实现与注意事项

- `MailPlainBody`是生产NSViewRepresentable；仍由原MailBodyPresentation创建token、按模块/目标重建。每次创建新原生视图，不隐藏保活，不缓存视图、TextKit文档或正文全文。
- `MailPlainController`使用有效viewport设置文本容器、完成公开TextKit布局、按保存文字索引查当前行，再恢复clip位置。只有当前token的第一次有效布局/恢复之后调用原`bodyDidDisplay`，复用原ViewingContext与已读去重；拖宽不会重复提供新的显示证明。
- 位置来自当前clip bounds通知，包含UTF-16文字索引和相对该行的垂直偏移。宽度变化时同一文字重新换行后定位；底部受当前可滚动范围限制。没有固定像素offset配新宽度的错误组合，也没有正文GET/网络重试来伪装恢复。
- 初始布局、宽度尚未同步、恢复操作内部及停止后的bounds通知都不保存。保存还检查当前render token、账号/epoch/generation/UIDVALIDITY和cache owner。停止只保留此前已采集的位置，不从可能已夹到顶部的拆除视图再取样；切另一封后旧回调和旧构造都不能覆盖新owner或撤销新显示证明。
- `MailPlainPositionCache`最近8封，每封只留身份、SHA256、owner与一个位置，没有全文/视图/位置历史。正文内容或身份不同从顶部开始；账号移除、更换、UIDVALIDITY或连接失效清除。超出最近8封允许从顶部打开，不跨App退出持久化。
- 直接赋NSTextView.string，`isEditable=false`、`isSelectable=true`、`isRichText=false`；关闭自动链接和自动数据检测。字面script/img/URL没有link或attachment属性，不走WebKit、富文本/HTML解析或资源下载。采用动态labelColor、透明背景、系统字体，空正文显示“（正文为空）”。深浅色像素、上下文菜单和真实键盘交互仍需实测。
- 只读选择需要允许原生文本获得焦点；既有AppState切模块先撤销first responder、再销毁工作区的规则保持。没有聊天发送入口或文本编辑绑定；不能把配置/自动调用测试等同于实际输入法和键盘隔离已验。
- TextKit对当前正文做完整布局，替代旧LazyVStack虚拟段落；长文本测试覆盖6000行，不作2MiB极限性能或实机流畅度承诺。缓存不额外保留全文，停止移除bounds observer与layout callback，实例由SwiftUI释放。

## 自动验证与红绿证据

证据目录：`tmp/2026-10-14-email-reader/r2-plain-scroll/`。全部内容合成，HTTP用既有URLProtocol，凭证fake，UserDefaults独立suite。测试属于serialized MailReaderTests，避免复用fixture并行污染。

| 检查 | 结果与日志 |
| --- | --- |
| 原生产视图先红 | `red-view.log`：宿主重建后的clip偏移0，预期>500，1项失败，正常exit1；旧UI仅开放internal以便测试，没有修复行为 |
| 原生重建先绿 | `green-view.log`：同一NSHostingView/NSViewRepresentable重建路径恢复750；最终测试进一步通过真实EmptyView替换触发dismantle |
| 宽度变化先红 | `targeted-red-width.log`：280→700换行后位置相对同一文字差656px，1项失败；其余7项通过 |
| 针对性绿 | `targeted-green.log`：8项通过；宽度变化按保存文字重新布局/恢复 |
| 最终全量 | `cd mac && make test`：Core74、App90通过，App2.225秒，`tests-final.log`；新增9项，保留HTML/列表/已读/通知/凭证/模块回归 |
| 构建 | `cd mac && make build`：Build Succeeded，`build-final.log`；未跑formatter/linter，未改签名配置 |
| 清理 | `mac-dev-cleanup --only browser --min-age 2`，exit0，nothing to clean，`cleanup-browser.log`；`remaining-test-processes.txt`为空 |

新测试覆盖：实际SwiftUI宿主重建750偏移、280↔700宽度及换行文字位置、字面HTML/URL/无attachment/link、只读/选择/检测开关、Aqua/Dark Aqua系统颜色解析、空正文/6000行长文、切另一封/旧通知/旧构造/旧stop、零尺寸/初始化/停止后迟到layout、正文与连接改变从顶部、账号/UIDVALIDITY/generation/epoch隔离、缓存上限，以及6次无延迟重建仍恢复750。生产layout在Messages可形成当前文档证明但不read，切Email才read一次，重复重建保持一次且send为0；HTTP成功本身没有显示证明。

测试有界等待沿用waitReader的400×5ms；宿主布局回归循环20×10ms。没有窗口、AX、屏幕事件、截图或真实请求。最初颜色测试误用UIKit的resolvedColor导致编译失败，改用AppKit的当前appearance/usingColorSpace后通过；这不是产品红证据。native-*.log保留未采用的SwiftUI探路，最终结论以上述全量为准。

## 交给协调者：独立复验最小步骤

1. 用户另开独立tab，从最新提交重建正常隔离App；沿用F1b独立bundle/ad-hoc、fake SecItem、独立HOME/偏好与外部合成服务。不得沿用F1b旧二进制，不改正式App或真实数据。先遵守context/桌面约定，本tab未开始这些步骤。
2. 复用F1b `fixture.py`/`scroll_checks.py`及AX采证方式，确认18874空闲并更新独立bundle定位。优先正常renderer，不注入代码。选择合成纯文本159，记录窗口大小、正文GET/read/资源基数；正文实际滚动750，确认清楚文字段落，采PNG/AX/control。
3. 只切Messages→Email，等待正常布局后采同组证据，比较**同一新原生renderer切换前后**首可见文字及几何，不拿旧SwiftUI字号/行高要求像素完全一致。至少重复一次；再159→158→159、快速模块/目标切换，确认选择/列表保持、不串位置。新NSTextView的AX结构与旧SwiftUI逐Text元素不同，工具需按实际AX适配，不能把找不到旧段落节点当产品失败。
4. 新原生视图必须补验：实际800×460窄窗、鼠标连续拖宽/拖窄后的换行及同一文字位置；深浅色文字/选择高亮/背景；空正文与长正文的可读性、滚动/恢复及响应速度。自动宽度/颜色解析不是鼠标拖动或屏幕像素证据。
5. 实际选择、复制纯文本；输入普通字符/中文组字/粘贴/Return，确认正文不变、聊天send计数不增加，切模块聊天草稿/焦点保持。原生只读配置测试不能替代该项；不要在真实聊天操作。
6. 字面script/img/HTTP URL/日期始终原样，不产生富文本、自动链接、检测附件或资源请求；核对fixture资源零增量。纯文本没有新增链接外开能力，保留字面文本；HTML已通过的HTTP(S)用户外开契约不变。
7. 核对正文GET/read：加载或初始化、离开/后台/关窗、旧layout不read；当前纯文本恢复并满足可见性后才合法read一次。原生布局回调是新显示入口，应有实际UI与请求时刻的关联证据；只依据总read+1不能判断旧回调缺陷。
8. 合成身份/UIDVALIDITY/正文改变应从顶部打开；HTML160简短切模块恢复回归、列表选择/锚点及聊天草稿/Email键盘回归即可。HTML安全/导航生产源码无变动，不重做已通过契约，不开始F2。新截图按项目规则归档，独立结果另写session。

## 遗留问题与范围外事项

纯文本P2自动修复待上述独立实机签收；known-issues不删除，原F1b失败仍保留。旧F1“通过”和F1b失败的具体布局时序差异未知，需带原生当前复验结果交协调者判断，不能宣称本次已获得第二次屏幕复现。

未知能力稳定UI、精确旧HTML didFinish乱序与已发STORE身份竞态、HTTPS/单标签内网外开和跨邮件/token动态探测沿用F1b未验清单；真正SecItem、通知、Dock、实际睡眠/唤醒/退出与完整聊天回归仍留F2，真实邮件读写仍需指定测试目标。本任务没有发现新的范围外确认产品缺陷，没有顺手修这些项目。

## 修改的文件与清理

- `MailPlainController.swift`、`MailPlainPositionCache.swift`、`UI/MailPlainBody.swift`：原生纯文本布局、位置与生命周期；`MailMessageDetail.swift`仅删除旧纯文本实现并调用同名新视图，HTML部分不改。
- `MailState.swift`、`MailState+Reader.swift`：接入有界纯文本位置缓存及原有失效清理。
- `MailPlainScrollTests.swift`：9项新回归；`MailReaderTests.swift`只加合成请求计数helper；`mac/Package.swift`编译实际纯文本NSViewRepresentable供无窗口测试。
- 根/mac AGENTS、README、原计划、module-shell/email-foundation、known-issues/next-up及本报告：同步当前实现和独立复验边界。协调文档只读，没有勾F1/F/F2。

所有controller通过stop移除observer/layout callback，宿主EmptyView替换拆除原生视图，测试WK沿用既有teardown，reader任务停止、临时UserDefaults domain删除。没有自建监听、App窗口、caffeinate、浏览器或模拟器；定向cleanup未清用户/其他tab资源。无swiftpm-testing-helper/xcodebuild残留。新测试没有截图，原F1b失败截图保留原归档；tmp日志/文档更新脚本保留供接续。

代码与必要文档同次提交，只暂存本任务文件。完成停在R2，提交及干净工作区状态在本tab最终报告。

## 相关文档

- [协调计划/R2](../plans/2026-10-13-email-reader-coordination.md) — 完整读取、只读任务边界。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 滚动/显示/已读契约及自动状态更新。
- [D2交接](2026-10-13-email-reader-d2.md)、[R1报告](2026-10-14-email-html-scroll-r1.md)、[F1b独立报告](2026-10-14-email-reader-f1b-acceptance.md) — 实际接口、HTML已通过边界、纯文本失败及未验矩阵。
- [模块外壳](../docs/module-shell.md)、[邮件基础](../docs/email-foundation.md) — 原生正文及恢复/显示边界。
- [known-issues](../known-issues.md)、[next-up](../next-up.md) — 保留独立复验与范围外关卡。
