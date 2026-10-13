# 邮箱阅读器 F1：独立隔离 UI、WebKit 与可见性已读验收

## 概要

在当前 master 完成 F1 的主要隔离验收。配置、100/50 分页、原生阅读、真实 WebKit 资源隔离、规则失败封闭、前台可见性已读及聊天键盘回归有独立证据；发现 **P2：Messages → Email 后 HTML 正文回到顶部**，不能完整签收 F1。浅色、鼠标拖宽、旧 cursor 完整恢复和连接变化时旧 HTML 回调的独立辨别等仍未验，交协调者安排接续。没有修产品代码，没有开始 F2。

基线 HEAD 为 `d2e4d8ab41211306d26d5ebc7a54951503507866`，产品实现基线为 E 的 `d1af9b1`。开始时工作区干净，全程当前 master；协调文档只读，没有创建分支/worktree、委派、push 或发布。

证据全部归档在 `tmp/2026-10-14-email-reader/f1-acceptance/`，下文编号指该目录同名前缀的 PNG、`-ax.txt` 和 `-control.json`。80 张根目录 PNG 经非黑图检查；这个检查只排除截图空黑，不能代替逐项判断。截图、脚本和隔离构建被 gitignore，留在本机；本报告与必要文档一起提交。

## 约定与隔离边界

- 已完整读协调文档及「当前任务 F1」要求，阅读原计划、根/mac AGENTS、B 验收、D1/D2/E 交接、模块外壳/邮件基础文档、known-issues/next-up 和桌面测试约定。采用 SwiftUI、impeccable、kb 与 systools 的相关约定。
- 实机前 `agent-inspect-session.sh` 为 23%；中途复查至 37%。协调者提示当前约 40% 后再次执行，自动压缩后的读数为 4%；此时仍停止新增实机检查，收拢已有证据，未继续执行浅色补测。GUI 前执行 wake-screen，显示保持只用有限 `caffeinate -d -t 3600`。
- 启动前未发现正式 FeishuChat 实例，18874/18875 空闲；不用 `make run`。由当前 mac 源码复制到 tmp 后独立 `make build`，改**副本** bundle id 为 `com.reorx.FeishuChat.f1-acceptance`，ad-hoc 签名；正式 bundle/signature/project 不改。
- 正常副本 `FeishuChat-F1.app` 的 MailState、Reader、正文 UI 和 HTML renderer 使用产品源码。为保证保存按钮也不访问真实钥匙串，副本 `MailSecItemOperations.system` 替换成 fake：读返回 notFound，写/删返回成功。仅外部模式不足以隔离保存时的 SecItem，不能把这次结果当真实钥匙串验证。
- 外部后端固定 `http://127.0.0.1:18874`，token 为合成 `synthetic-f1-only`；无正式后端子进程、IMAP、工作账号或数据副本。最初启动设置 tmp HOME/FEISHU_LITE_HOME；部分外部模式重启未重复设置 HOME，仍使用独立 bundle 偏好和假 SecItem，未启动正式后端或读取正式数据。未读取 env 文件。
- `fixture.py` 组合 B 合成聊天和 D2 合成邮件：账号 UUID `00000000-0000-4000-8000-0000000000d2`、INBOX/UIDVALIDITY 77、160 封邮件、60 个聊天。配置、Seen 和资源/请求日志只在模拟进程内存；没有访问真实邮箱或给工作会话发送消息。
- 故障副本 `FeishuChat-F1-Gate.app` 另在 **tmp** 的 `MailHTMLController.compileRules()` 加 `rule-mode` 注入：4 秒延迟、抛 unavailable 或正常编译，保留生产 gate/controller、WK 配置与 delegate 调用链，不绕过安全门。55–60、78–81 属于此边界；成功 HTML 基础检查先用未改 renderer 的普通副本。
- `source-manifest.json` 对比所有 App Swift 文件，仅假 Keychain 与规则故障注入两个文件不同。浅色专用副本另有测试 Info.plist 强制 Aqua，但没有实际启动验收，不能作为浅色证据。

## 完整结果矩阵

### 配置、兼容与状态

| 检查 | 结果 | 实际与证据 |
| --- | --- | --- |
| 未配置引导、邮箱与扫码聊天身份独立、固定 TLS 提示 | 通过 | 39/40 配置页可操作，独立身份说明存在；只输入合成地址/密码。 |
| 测试连接不保存；只读结果提示 | 通过 | 40：`POST /mail/account/test=1`，`PUT /mail/account=0`，仍未配置；显示“连接成功，但邮箱只读，无法同步已读状态”。这是模拟只读结果，不是真实 SELECT。 |
| 试连可恢复失败、随后保存 | 通过 | 41 安全错误文案，42 保存一次 PUT 后 connecting，43 收件箱 online。 |
| 修改专用密码 | 通过，fake 边界 | 44 对 credential PUT 一次并进入 connecting；无实际 SecItem。截图时曾出现系统密码自动填充建议，但未选择建议，后台请求是合成输入。 |
| credential_missing / auth_failed / offline | 通过 | 45–47 显示对应状态；离线保留整箱计数和已有列表，不触发聊天扫码。 |
| 长中文地址、窄配置、移除确认/取消/真正移除 | 通过 | 中文输入工具失败的48不算证据；61由合成状态提供长中文地址，800×512窗口中配置可读/滚动；49–50取消不删；62确认，63实际 `DELETE /mail/account=1`、邮箱未配置/计数归零，聊天保留。 |
| 旧后端安装命令、重新检测 | 通过 | 64 无残留确认框，显示安装引导与“已安装，重新检测”，读取模拟不支持 mail 的健康信息。52–53被模态框遮挡，不作为签收依据。 |
| 未知能力期间的加载 UI | 未验 | 假后端过快完成能力发现，没有独立稳定截图。 |
| 真正钥匙串无条目、拒绝/锁定、写入失败 UI、App 重启恢复、Debug/Release 互访 | 未验 | 假 Keychain 成功写入和外部模式不能覆盖这些路径；真实 SecItem 留 F2，拒绝/写失败等模拟 UI 可由接续 tab 补。 |

### 列表、阅读与界面

| 检查 | 结果 | 实际与证据 |
| --- | --- | --- |
| 全部文件夹、中文层级、Noselect、非 INBOX 禁用 | 通过 | 71 AX/menu 区域截图：中文分类/子目录存在，Noselect 和非收件箱菜单 enabled=false；内容请求仅 INBOX。 |
| 首批100、后续50、尾页10、UID降序、手动刷新 | 通过 | 11–13：cursor 61、11，列表分别到 UID61、11、1；14刷新新前缀164→1，请求 cursor65、15，保留已加载最旧边界UID1及当前正文159，未读badge仍来自整箱321减Seen，而非列表条数。 |
| 新信插入时列表落点/选择保持 | 通过 | 13→14首可见合成纯文本24仍在原落点，当前纯文本159不变。 |
| 旧 cursor 错误显示与已有数据保留 | 通过（错误阶段） | 15返回410后“邮箱状态已变化，请刷新后重试。”及“重试加载收件箱”出现，原列表/选择保留。 |
| 旧 cursor 完整恢复 | 未验 | 最后83在分页410后已发首屏重取且错误消失，工具随后找不到“重试加载收件箱”而退出；84没有生成。不能将按钮定位失败记为产品缺陷，也不能宣称边界/选择完全恢复。 |
| 长中文主题/发件人、空主题/发件人、未读标识 | 通过 | 65、66：长主题头部可滚动，空字段为“（无主题）”“未知发件人”；蓝点/已读变化有 AX 与计数。 |
| 纯文本字面 script、HTML、空正文 | 通过 | 06字面 `<script>literal</script>`；02/05 HTML文字可读；67空正文有明确空态。 |
| 附件信息及约数/未知大小 | 通过 | 82真正展开：`合成附件.txt`、`text/plain · 约 256 bytes`，`大小未知的合成附件.bin`、`application/octet-stream`；没有下载/打开附件。65只是标题点击，不能独立证明展开。 |
| 正文失败与重试 | 通过 | 19加载失败不read；20“重试正文”后正文显示、目标read增加一次。 |
| 离线已缓存/未缓存 | 通过，合成缓存边界 | 21假后端离线仍返回缓存正文、无read；22恢复online补判。68未缓存报错，69恢复后重试成功。未测试真实 mail.db 缓存。 |
| 删除当前目标 | 通过 | 70合成删除事件后回收件箱/取消当前正文，不沿用已删除目标。 |
| 最小内容800×460、配置/阅读来回、980×680布局 | 通过 | 61/65/82窗口800×512（含52高工具栏，内容800×460）；01–10及74以后980×680。两栏、头部/正文与配置可操作。 |
| 鼠标拖宽 | 未验 | 72模拟拖角后 AX仍800×512，未证实拖动命中；程序设置尺寸有效不等于鼠标拖宽通过。 |
| 深色 | 通过 | 74及主要截图为实际深色，正文/菜单/状态可读。 |
| 浅色 | 未验 | 73写 per-app AppleInterfaceStyle Light 后截图仍深色；强制Aqua副本85/86尚未执行。工具切换无效，非产品缺陷。 |
| 列表/纯文本位置恢复 | 通过（条目标识） | 09→10列表首可见146相同；07→08纯文本段落026/027附近保持，几何约2px差；不宣称完全相同像素。 |
| HTML位置恢复 | **失败 P2** | 03→04以及32→33复现：切Messages再切Email回到页顶；详见下面缺陷。 |
| Email回车不发送聊天、草稿/两处聊天锚点、旧聊天未读隔离 | 通过（本轮有限回归） | 75–77输入合成草稿`F1-chat-draft-keep`；Email输入/两次回车，聊天send始终0。聊天04新增未读留在Email，不调用read；切回再补一次read。聊天列表首会话16、详情首可见消息090恢复，像素有20–25px偏移。不是F2完整聊天回归。 |

### 真实 WebKit 安全与规则门

| 检查 | 结果 | 实际与证据 |
| --- | --- | --- |
| 恶意原始HTML绕过后端净化；净化HTML；纯文本 | 通过 | 02、05、06分别运行；02直接进App的 adversarial HTML不是净化输出。标题/段落可读，资源probe均空。 |
| 首封、第二封、切回自动资源零请求 | 通过 | 02–05、34、55–58资源计数空；切回失败的是滚动，安全计数不增加。 |
| JS/handler、CSS URL/stylesheet、远程图、iframe/object、meta导航、form | 通过（fixture覆盖范围） | 实际 WK 页面执行，脚本执行marker不出现；JS/fetch/handler/css/sheet/frame/object/redirect/form端点均无请求。iframe可能有空框占位，不能将空框当资源加载成功。 |
| CID/file图片、本机URL自动加载 | 通过（合成目标） | CID/file不显示资源；后期fixture提供实际存在的`local-probe.svg`，56无“LOCAL FILE RESOURCE LOADED”标记。只检查指定合成文件，不探测系统文件。localhost自动资源端点也零请求。 |
| 普通HTTP与_blank外开；IP/localhost合法用户链接 | 通过 | 先34确认自动资源零，再35/36/37用户点击；外部Chrome分别访问 `/probe/user-normal`、`/probe/user-blank`、`/probe/user-intranet`各1次。最后一项实际是localhost，不能扩大为所有内网主机验证。 |
| 自动导航、JS/data/file/custom scheme链接、form提交 | 通过（本fixture） | 38对可见禁用链接/表单操作，probe与37完全相同，无额外打开；非HTTP(S)路径不会交外部浏览器。 |
| 用户HTTPS、单标签内网主机外开 | 未验 | 为不联网仅点击loopback HTTP/IP/localhost；策略自动测试允许合法HTTP(S)，不是这两种实际外开证据。 |
| 非持久WK、token/聊天凭证/其他邮件数据隔离 | 部分通过 | 配置/生产delegate调用链由3项专项测试及源码对照验证；实际资源/脚本禁用有上述证据。没有实机跨邮件数据访问或带token窃取探测，不能扩大为全部动态访问测试。 |
| 规则完成前首封不得显示/read | 通过，故障注入 | 55 HTTP正文已返回但4秒规则仍pending，页面未加载、read160=0；56规则完成才显示，read160=1、资源仍零。 |
| 编译失败封闭、显式重试 | 通过，故障注入 | 57规则抛错→安全失败页、read157=0；恢复正常再58重试，read157=1。没有在失败时绕过规则。 |
| 视图拆除后迟到编译不得产生显示证据 | 通过，故障注入 | 78→79在新世代/清Seen且新App后复验，等待期间切Messages，read160保持1（本进程历史基数），未新增；80回Email新视图完成后变2。59–60已读目标也通过，但不能单靠去重掩盖迟到问题。 |
| 连接世代变化时旧HTML回调 | 未验（不能判缺陷） | 80→81 uid157 read从1→2；在线generation变化会触发新Reader刷新/重新展示，81确有当前正文。日志未关联render token/generation与请求时刻，无法辨别这一次是否来自合法新渲染。原`independent-checks.json`保留这条“预期0、实际1”的失败统计，**它是测试断言不足，不登记第二个产品缺陷**。 |

### 可见性已读

以下均比较同一模拟进程的计数差值；重启服务后的计数不能跨阶段相减。Seen只写内存。HTTP加载成功本身不等于显示，55提供HTTP返回而read为0的实际对照。

| 检查 | 结果 | 请求证据 |
| --- | --- | --- |
| 正常纯文本/HTML成功显示才read一次 | 通过 | 02/06和55→56；返回已读正文不反复提交。 |
| 慢正文/快速换目标的迟到返回 | 通过 | 17→18 uid158无新增read，目标159正常显示；旧158不能覆盖当前选择。 |
| 失败正文不read，重试成功才read | 通过 | 19→20 uid158 +1，失败阶段没有新增。 |
| 离线显示缓存不read；在线仍显示补判 | 通过 | 21→22 uid153 +1，仅online后增加。 |
| STORE结果不确定不自动重试；明确重试入口 | 通过 | 23→24 uid152无新增；25点击“重试已读同步”后+1，未确认前不假装清未读。 |
| 请求在Messages完成不read，切回Email补判 | 通过 | 26→27 uid151 +1，仅切回后增加。 |
| 后台完成不read，返回前台补判 | 通过 | 28 Finder前台时无新增150，29激活后+1。 |
| 关闭窗口完成不read，重开补判 | 通过（局部窗口行为） | 独立`close_window.py`重验uid148，30关窗计数、31重开后+1；30没有截图，因为窗口已关闭。旧visibility.py的149键盘关窗工具失败不算依据。完整退出/唤醒仍是F2。 |
| HTML视图拆除迟到编译 | 通过 | 78–80差值见上表。 |
| 已读期间账号更换/UIDVALIDITY变化；旧didFinish与新navigation的精确归因 | 未验 | 账号移除/删除UI通过不等于这些竞态通过；81归因不足，交接续tab补测。 |

## 已确认缺陷：HTML切模块后丢失阅读位置（P2）

预期：Email的HTML邮件滚动位置保存在内存，切Messages再返回同一邮件应恢复到原位置。实际：邮件选择与数据不变，正文回到顶部，需要重新寻找阅读段落。长邮件反复切换聊天时明显影响使用；没有证据表明它导致资源加载或错误已读。

最小复现（正常副本，未注入规则延迟/失败）：

1. 合成后端online，打开Email的“安全 HTML 160”，窗口980×680。
2. 在正文区域 `(800,500)` 向下滚约750，保存03。
3. 点击Messages，再点击Email；正文完成后保存04。
4. 03正文viewport `y=313,h=418`，段落008在`y=336`；04页顶标题/空iframe框重新出现，段落001在`y=813`。选择仍uid160，read160仍1、资源probe仍空。32–33较短滚动又复现一次。

证据：`03-html-scroll-before.*`、`04-html-scroll-restored.*`、`32-html-second-restoration-before.*`、`33-html-second-restoration-after.*`。`reading.py`提供步骤，但连带执行其他检查；只复现本缺陷应按上述四步。建议协调者派返修检查公开 `interactionState` 的保存/恢复时机与页面布局完成后的实际效果，随后在独立tab用最新产品构建复验。这里只给排查方向，不推断已证实根因，不改产品代码。

## 自动核对与工具定位纠正

- 普通隔离App和规则故障App的 Debug构建成功：`build-isolated.log`、`build-gate.log`。故障注入最初因函数新增多语句漏return导致工具副本编译失败，修的是tmp注入，不是产品。
- 产品 `swift test --filter MailHTMLGateTests`：3项通过，日志`gate-tests.log`，验证首载保护/退役compiler/实际WK配置和两delegate路径。它补充实际安全证据，不替代WebKit UI。
- `audit_evidence.py`：23项记录，22项匹配；连接世代用例1项预期不足，按上述未验处理，原失败记录保留。80张截图无黑图；源文件差异只有fake SecItem和compileRules注入。`saved-summary.json`汇总各阶段read、分页、窗口与AX；完整原始请求以每张control文件为准。
- 全套测试没有重复运行；引用E已交付的后端301/Core74/App67，不算本tab重新通过。全套与系统集成复核留F2。
- 曾出现旧uvicorn因SSE连接仍持有旧socket、普通quit被确认模态挡住、AX命中屏幕外行/重复按钮、Unicode键盘输入失效及截图捕获密码建议小窗口。均先修fixture/AX定位并重验：17–31、35–38、55–60、61–64/82使用最终证据。
- 48不证明中文，51不证明移除，52–53不证明无遮挡兼容页，65不证明附件展开，72不证明拖宽，73不证明浅色，81不证明旧连接回调安全，83不证明完整cursor恢复。文件名是当时意图，结论以上述矩阵为准，避免把工具失败或旧证据名当产品缺陷。
- 弹出的测试窗口/可能权限提示已由用户提前获知；无需扫码，未访问真实登录页或执行真实邮箱/钥匙串操作。

## 遗留问题与复现入口

F1接续优先修HTML滚动，随后补未验项：浅色、鼠标拖宽、旧cursor的完整恢复、未知能力加载UI、fake Keychain失败/拒绝文案、账号/UIDVALIDITY/连接变化的渲染竞态。HTTP(S)策略可在本机合成TLS页面补HTTPS外开，不需要访问外网；单标签内网主机应使用可解析的合成目标。不要为测试读取工作邮箱。

可复用入口均在上述tmp目录：

```sh
# 从项目根目录执行；先检查18874空闲。
uv run --project backend python tmp/2026-10-14-email-reader/f1-acceptance/fixture.py

# 另一个终端：基线复现使用现存普通副本，全部参数为合成值。
open -n --env FEISHU_LITE_BACKEND_URL=http://127.0.0.1:18874 \
  --env FEISHU_LITE_TOKEN=synthetic-f1-only \
  tmp/2026-10-14-email-reader/f1-acceptance/FeishuChat-F1.app
```

`fixture.py`依赖本机仍保留的B `mock_backend.py`与D2 `safety_fixture.py`；`/f1-control`GET取得计数、POST设置合成状态，字段定义在fixture顶部。`ui.py`/`ax.swift`可复用定位，但须检查目标在viewport、模态与bundle身份；不能盲跑全部旧脚本。`gate_unread.py`的最后连接变化断言需要改进归因，不能直接当合格回归脚本。`extras.py`最后的按钮定位失败已记录，不能假设84–86生成。

返修验收必须从**最新当前产品源码**重建新的隔离副本，重新应用假SecItem与独立bundle；现存App只代表本报告基线，不能用旧App验收新修复。故障注入只针对新副本，普通成功路径保留原renderer。实机前仍做context/桌面约定检查。

F2保留：真实系统通知投递/点击/清理/ack与未知intent恢复、测试UUID的真实SecItem及Debug/Release授权、实际Dock、睡眠/唤醒/退出与supervisor、完整聊天回归和全套检查。真实邮箱Seen/跨端/新信继续等待用户指定测试邮件与来源，本次没有扩大授权。

## 资源清理

已停止独立bundle的所有F1 App；只终止自己的fixture Python18404/uv18402与显示caffeinate47016。18874/18875没有listener，无F1 App/fixture进程；没有启动模拟器或agent-browser。执行 `mac-dev-cleanup --only browser --min-age 2`，结果nothing to clean、exit0，未清其他会话。

三次外开只关闭当前URL完全匹配本次loopback probe的Chrome tab，保留用户浏览器；没有创建headless浏览器。删除独立UserDefaults域`com.reorx.FeishuChat.f1-acceptance`。模拟账号/Seen在服务退出时释放；没有真正钥匙串条目需删，没有复制真实数据。脚本、HTML/local SVG、构建、日志与截图作为证据保留；详细清理记录`cleanup.txt`。其他非本次显式创建的短时caffeinate不处理。

## 修改的文件

- 本session：结果矩阵、缺陷、原始证据边界与接续入口。
- `kb/known-issues.md`：用已确认HTML滚动缺陷和剩余精确未验项替换“阅读器全部尚未UI验收”。
- `kb/next-up.md`：改为协调返修后复验和补齐F1剩余项，系统集成单列F2。
- 根/mac `AGENTS.md`、`README.md`、`kb/docs/module-shell.md`、`email-foundation.md`及原计划：同步实际F1结果；完整阶段和超出证据的检查项保持未勾选。协调文档不改。

## 已解决的已知问题

原“实际WebKit隔离与界面仍未独立验收”的大部分空白已补：实际资源/脚本、HTTP/_blank、规则门、主要阅读/配置、最小内容窗口和可见性已读有独立证据；剩余未验和HTML滚动缺陷继续登记，未将整个D/F阶段关闭。

## 交给协调者

请派HTML滚动返修；新tab接续本报告未验项并审查81的事件归因。F1有明确P2和未验项，不能无条件签收；多数独立检查通过，不必重复全部已验证过程，但新修复涉及renderer时需重验首载规则门、资源隔离和可见性已读。主会话可据此决定返修/接续顺序；F2未启动。

## 相关文档

- [协调文档](../plans/2026-10-13-email-reader-coordination.md) — 本次只读依据，不更新阶段状态。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 同步有证据的F1子项。
- [B独立验收](2026-10-13-email-shell-b-acceptance.md)、[D1](2026-10-13-email-configuration-d1.md)、[D2](2026-10-13-email-reader-d2.md)、[E](2026-10-14-email-notifications-e.md) — 读取接口/验收边界，真实系统行为留F2。
- [模块外壳](../docs/module-shell.md)、[邮件基础](../docs/email-foundation.md) — 同步滚动恢复与安全验证的实际状态。
