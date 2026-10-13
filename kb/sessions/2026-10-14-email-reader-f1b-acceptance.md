---
created: 2026-10-14
tags:
  - email
  - acceptance
  - webkit
  - scroll
---

# F1b：HTML 滚动 R1 独立复验与 F1 接续

## 概要

**R1 可签收**：从最新源码重建的正常隔离 App，HTML160 切 Messages 再回来、160→157→160、反复快速切换都恢复原段落及几何位置。新增内存 scheme 在真实 WK 首载/恢复中只供应精确主文档，自动资源零请求，精确 URL 的图片/样式/frame/object及普通/_blank用户链接不能借例外加载。规则延迟/失败继续封闭，当前导航完成后才产生显示及已读证据。

补齐浅色、鼠标拖宽、旧 cursor 完整恢复和 fake Keychain 缺失/拒绝/锁定/写失败 UI；身份重置与连接变化下的退役展示没有新增 read。**新 P2：纯文本邮件159切模块返回回顶，单次复现，截图与AX一致，尚未返修。F1仍有失败及精确未验项，不签收整个F1/F，不启动F2。** 本次不改产品，未访问真实数据、env、IMAP、SecItem、工作会话或真实 Seen，没有委派、换分支、push或发布。

开始 HEAD `ca27d38`，产品基线 `f148274`，当前 master、工作区干净。完整阅读协调文档及当前F1b，根/mac AGENTS、桌面约定、原计划§7、F1/R1报告及相关接口文档。使用 kb、SwiftUI、impeccable、systools相关指导。GUI前context20%，接续25/27/29/33/35/36/38%，最后38%即停止新增GUI，没有靠压缩延长验收。

证据目录：`tmp/2026-10-14-email-reader/f1b-acceptance/`。下文编号对应PNG、AX和control JSON。最终51张PNG均非黑图；`final-audit.json`保存计数、身份及亮度，`presentation.log`保存导航关联。截图在本机gitignored目录，文档入库。

## 隔离与源码差异

- 启动前无FeishuChat实例，18874空闲。复制当前mac源码到tmp，排除构建目录、真实签名Local.xcconfig和env文件，走副本Makefile重新构建。副本独立bundle `com.reorx.FeishuChat.f1b-acceptance`、ad-hoc签名，正式工程/签名不改、不make run。
- 正常 `FeishuChat-F1b.app`：所有产品Swift源码一致，唯一差异是 `MailSecItemOperations.system` 用fake（notFound/写删成功）。`source-manifest.json`记录哈希；01–12及正常恢复证据无renderer观察/故障注入。
- 浅色 `FeishuChat-F1b-Light.app` 是正常副本加测试Info.plist `NSRequiresAquaSystemAppearance=true`；13/14实图确为浅色。不是更改用户全局外观，也不声称验证了系统外观切换动画。
- 后续 `FeishuChat-F1b-Observed2.app` 的差异在 `observed-differences.json`：fake Keychain及其可控错误；新增F1bProbe；Controller/Document/Reader只加合成导航、token、read时间记录；Controller包装正文前把攻击样本占位符换为本次随机精确URL，并在新 `compileRules(documentURL:)` 注入normal/4秒delay/fail。规则、CSP、delegate、恢复/gate路径不改，不绕安全门。
- fake读取UI另通过 `F1B_FAKE_CREDENTIAL_RESTORE=1` 在AppState构造MailState时把其externalBackend参数改为false，仅开启生产凭证恢复分支。Supervisor仍使用外部后端，不拉正式后端。此差异只用于37–39/44–45，不是实际SecItem或正常外部模式的自动读取证据。
- 所有启动传独立HOME和FEISHU_LITE_HOME，外部合成后端 `127.0.0.1:18874`；合成账号d2/b2、UIDVALIDITY77/78，配置/Seen只在fixture内存。未复制真实数据，未读取env文件。fixture复用F1/B/D2并扩展scheme恶意输入、身份/世代与请求时间；第一次服务退出后计数重新开始，不能跨两次进程相减。
- 用户已获知隔离窗口。GUI前wake-screen，有限caffeinate；Chrome只开本机合成链接，关闭每个精确URL匹配的本次tab，不退出用户浏览器。

## 新增结果矩阵

| 检查 | 判定 | 实际证据与边界 |
| --- | --- | --- |
| HTML160切模块恢复 | 通过 | 02→03：首个完整段落008均 `x505,y336,h19`，WebArea均 `y=-437,h5197`。独立查看PNG，未回顶；只有列表焦点高亮不同。 |
| 切另一封与快速重复切换 | 通过 | 05/07：157首完整段落006均y342；06返回160仍008y336；08三次80ms间隔模块切换仍008y336。160和157不串位置。 |
| 纯文本恢复 | 失败，P2，单次复现 | 10→11：切换前首完整段落026在y311，返回后首完整段落000在y333，026移到y1061。PNG明确回顶；同一封159、窗口及身份不变。列表及正文选择保持，read及资源没有增加。既有列表恢复沿用F1，不能沿用其纯文本通过结论覆盖本次失败。 |
| 鼠标实际拖宽 | 通过 | 12：cliclick拖右边缘1079→1199，AX宽980→1100、高680；截图可读。不是用AX设置尺寸冒充拖动。 |
| 实际浅色与最小内容布局 | 通过 | 13/14在800×512外窗（内容800×460）显示浅色HTML与配置；已目视白色正文、浅色栏、深色文字，深色引用01–12。 |
| 原始恶意HTML/净化HTML/纯文本 | 通过 | 正常副本01/04/09及恢复03/06/08：可读、SCRIPT EXECUTED与LOCAL FILE RESOURCE LOADED未出现，资源计数一直空。160绕过后端净化，157使用净化输出；纯文本script是字面文本。 |
| 新scheme首载/恢复、精确URL子资源及其他URL | 通过（观察副本） | 15–17：每次presentation仅一次精确主文档scheme request，恢复使用同URL；精确URL img/stylesheet/iframe/object和同scheme其他URL都未到handler，没有嵌套正文。空iframe框不算资源加载。HTTP/CSS/JS/handler/图片/CID/file/iframe/object/meta/form自动端点均零。 |
| 精确scheme普通/_blank及其他scheme用户链接 | 通过 | 普通与其他URL在18的policy type0 allow=false；初次_blank点击命中包围盒空白，不算证据。42→43纠正到换行文字后，精确URL `main=false,type=0,allow=false`，scheme request与资源/read未增加。 |
| 普通HTTP、_blank、IP/localhost外开 | 通过 | 先18确认自动零，再19外部Chrome各请求user-normal/user-blank/user-intranet一次并关闭对应tab。正常/_blank仍走实际生产delegate。后续资源计数只保留这三次用户请求，自动增量为零。未点击HTTPS或单标签主机。 |
| 规则完成前首载不得显示/read | 通过，故障注入 | 20：HTTP已返回，Seen空、read总计1（之前scheme已读基数），无本presentation load/finish；21完成后read总计2、Seen160。 |
| 编译失败封闭与显式重试 | 通过，故障注入 | 22安全失败页，read仍2、没有157；23恢复normal、重试正文后read3、Seen157。 |
| 拆除/离开Email的迟到编译 | 通过 | 24清Seen后切Messages等4秒，read总计仍3；25返回当前presentation合法finish后变4，token匹配。不能只靠Seen去重掩盖旧回调。 |
| generation变化归因 | 通过（本用例） | 26旧4代/新5代期间切走，Seen空、总read4；27当前5代新navigation完成才read5、目标157。presentation/导航/提交时间与READ_SCOPE对应，不用“+1即错”判据。 |
| UIDVALIDITY/账号变化隔离 | 通过（待编译阶段） | 28/30重置取消选择且Seen空，累计read保持5/6；29/31用户重选当前160后从页顶显示、新URL且restore=false，合法当前finish后读到6/7。READ_SCOPE分别77/78及d2/b2，不串旧目标或位置。未覆盖已发STORE尚未返回的竞态。 |
| 旧cursor410完整恢复 | 通过 | 32已加载150封、最旧11、选159；33请求cursor11得到410后自动首屏及cursor61重取，列表最旧仍11、正文159不变、错误已消失；34再加载cursor11到尾页1。32/33首可见行位置相同；无需再找已经消失的重试按钮。 |
| fake Keychain缺失/拒绝/锁定 | 通过，输入注入边界 | 37显示无密码；38显式retry显示未获授权；39显示已锁定/不可交互。生产分类/配置UI工作，不访问真正SecItem。 |
| fake Keychain写失败/恢复 | 通过 | 初次40未正确输入，作废。44精确第二TextField输入合成密码、credential PUT一次后显示“密码尚未安全保存”“只留在内存”与重试；45fake恢复成功、重试后警告消失。 |
| Email键盘隔离/聊天未读 | 通过（有限回归） | 46–48和52–54，Email两次Return没有聊天send；Email收到chat04新未读时不read，返回Messages补一次，聊天read总计1→1→2。不是完整F2回归。 |
| 已提交草稿恢复 | 通过，AX设置边界 | 键盘模拟46–51未形成可靠提交，不作草稿证据。52/54通过AX SetValue设实际NSTextView文本，切模块前后均F1bCommittedDraft，send始终0。实际输入法仍留F2，不能把工具组字变化当产品丢草稿。 |
| 未知能力稳定加载UI | 未验 | delay健康/SSE会先停在Root全局启动页，Email按钮尚不存在；等待完成只得到ready，未取得“正在检测邮箱功能”稳定截图。没有强改MailState让它假通过。 |
| 精确旧didFinish回放/已发STORE期间换身份 | 未验 | 本次真实UI覆盖待编译退役、当前navigation及generation/账号/UIDVALIDITY清理；未制造真实旧navigation didFinish与当前navigation乱序回放，未在STORE已发后暂停响应并换账号。自动R1测试覆盖部分，不能冒充UI全通过。 |

## 证据核对与工具错误

- `build-isolated.log`、`build-observed.log`、`build-observed-final.log`均Build Succeeded。`swift test --filter MailHTMLGateTests`生产专项3项通过，`gate-tests.log`。未改产品、不重复全套；引用R1 Core74/App81及构建、E后端301，F2另行全量复核。
- `evidence-audit.txt`列滚动几何及read差值；`final-audit.json`列身份、分页、截图非黑图检查；`source-manifest.json`和`observed-differences.json`记录副本来源及差异。脚本exit0仅代表采证结束，结论来自PNG/AX/请求/导航联合判定。
- `presentation.log`中read-submit的完整token均有更早同token finish-accepted；再与fixture READ_SCOPE的当前账号/UIDVALIDITY/generation和时间对应。规则失败/退役目标没有finish-accepted或新的read-submit。日志中的旧历史记录不混入当次差值。
- 未知能力 `extras.py`的Email按钮缺失，是等待健康阶段与工具假设不符；不登记产品缺陷。40-password点击命中侧栏文字，按钮disabled，后续找不到保存重试；44–45重验有效。18包围盒中心不在换行链接文字，42–43重验有效。一次cliclick无效cmd-a参数及键盘/输入法造成的空或组字文本，均只属工具失败，52–54使用AX设置重验。
- 46→48聊天列表/详情落点有变化，本次工具曾滚动回顶并新增消息，不作为新的几何恢复结论；引用B/F1已通过锚点证据。不要把46–51文件名当成功声明。

## 与 F1 合并后的剩余项

F1已通过且不受R1影响的配置、文件夹、分页/刷新前缀、长字段、附件/空正文、离线/正文失败、后台/关窗/不确定已读入口等沿用原报告，不重复全部。F1b关闭原HTML滚动P2、浅色、鼠标拖宽、旧cursor完整恢复和fake凭证错误UI的验证空白；纯文本恢复另有本次失败，覆盖该子项原通过状态。

新P2最小复现：正常隔离副本（只有fake Keychain，无renderer注入）选择合成纯文本159，正文实际滚动750px，待0.7秒并采证10；只点Messages再Email，每次等待0.5秒，capture再等待0.5秒，采证11时已回顶。脚本 `scroll_checks.py` 没有在两次截图之间点击邮件、滚动正文或修改fixture；control JSON的config一致，GET正文及POST read159仍各1次，资源为空。截图与AX均证明这一次屏幕落点失败，不能解释为工具点错或HTML修复失败。末次审核发现并纠正先前草稿的“纯文本通过”误判；最后GUI context38%，不再开GUI重复，持续性/第二次复现及根因由独立返修接续，不能据此声称每次必现。验收者只登记，不改产品。

仍未验：未知能力稳定加载UI；精确旧didFinish/新navigation乱序及已发STORE期间身份变更；HTTPS与单标签内网主机实际外开；实际跨邮件数据/token读取攻击。最小接续：在隔离副本仅对能力输入延迟建立稳定unknown窗口；给controller观察记录补每个didFinish候选及navigation身份（不绕策略），用可控服务暂停read响应再换合成账号/世代；loopback TLS页面检验HTTPS。当前没有证据足够登记这些为新缺陷。

F2未展开：真正SecItem/Debug-Release互访、系统通知投递/点击/精确清理/ack与未知intent恢复、Dock、睡眠/唤醒/退出/supervisor和完整聊天回归/全套测试。真实Seen/跨端/新信仍须指定测试邮件及来源，本次不扩大授权。协调者可签收R1和上述F1子项，决定少量F1余项与F2的安排；整体F不提前关闭。

## 清理

停止本次独立bundle App、fixture uv66848/python66849、有限caffeinate66850；删除独立UserDefaults域及tmp隔离HOME/data。浏览器三个本机用户链接在点击后逐个关闭精确匹配tab，scheme点击没有新tab。无实际钥匙串条目、模拟器或agent-browser由本次创建。定向 `mac-dev-cleanup --only browser --min-age 2`，结果见cleanup-browser.log；保护其他会话。保留源码副本、构建、合成HTML、脚本、截图及日志作为证据，最终进程/端口检查见cleanup.txt。

## 修改的文件与已解决问题

只修改本session及必要状态文档（根/mac AGENTS、README、原计划、email-foundation/module-shell、known-issues/next-up），协调文档只读。产品源码无修改。HTML切模块回顶P2经过独立屏幕复验已解决；known-issues另登记本次纯文本回顶P2。F1未验项缩小并保留准确清单。报告与文档同次提交，当前master、不push。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 只读任务边界。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 更新有证据子项，F/F2保持未关闭。
- [F1报告](2026-10-14-email-reader-f1-acceptance.md)、[R1报告](2026-10-14-email-html-scroll-r1.md) — 原证据与本次独立判定依据。
- [模块外壳](../docs/module-shell.md)、[邮件基础](../docs/email-foundation.md) — 同步验证边界。
- [D1](2026-10-13-email-configuration-d1.md)、[D2](2026-10-13-email-reader-d2.md)、[E](2026-10-14-email-notifications-e.md) — 接口及系统集成接续。
