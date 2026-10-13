---
created: 2026-10-14
tags:
  - email
  - acceptance
  - notifications
  - macos
---

# F2a：真实系统通知、点击与 Dock 独立验收

## 概要

F2a 已完成证据收集与资源清理，**不能整体签收**：未知投递恢复提示与收件箱工具栏重叠，确认为 P2；稳定账号下运行中关闭通知权限、410/旧账号实际点击及系统 add 失败等仍未验。主要逐封/汇总投递、真实点击、跨进程 receipt/ack 去重、精确清理和 Dock 已通过。没有修改产品，也没有开展 F2b。

## 基线与隔离

- 当前 master 的源码副本来自 `836b68a`（协调文档提交）；brief 基线 `35c699e`，产品基线 `9559a3a`。完整阅读协调计划、原计划通知/验收契约、E 报告，接续 D1/D2 与 F1b/F1c 边界。只在本 tab 执行，没有委派。
- 证据、截图、工具和源码差异归档：`tmp/2026-10-14-email-reader/f2a-acceptance/`，下文文件名均相对该目录。`result-matrix.json`/`.txt` 关联每阶段系统、服务端与 PID；原始 `*-system.json`、`*-control.json`、`*-ax.txt` 和 PNG 保留。
- App 独立 bundle `com.reorx.FeishuChat.f2a-acceptance`，显示名“FeishuChat F2a 合成测试”；独立 HOME、FEISHU_LITE_HOME、UserDefaults 域，外部 loopback 合成 HTTP/SSE 服务 `127.0.0.1:18875`。MailSecItemOperations 全部替换为无真实调用的假钥匙串；没有读取真实 env、缓存、邮箱密码或工作邮件，没有发真实消息、写真实 Seen、启动正式 App 或改其签名/权限。
- Debug arm64、副本 `make build` 两次成功。签名 `Apple Development: Xiao Meng (P3X7S2FBA5)`，实际 TeamIdentifier `YU3FMV36N2`，hardened runtime；见 `signature.txt`、最终 `signature-final.txt`/`signature-final-verification.txt`（strict签名验证成功）、`build.log`、`build-pending-observer.log`。首次误把证书括号内值当 Team ID 的构建失败是工具配置错误，修正副本后成功，不算产品失败。未重复 E/R2 已通过的无关全套测试。
- `source-manifest-final.json` / `source-differences-final.txt` 审计所有 Swift/工程配置。差异仅测试 bundle/显示名/签名、fake SecItem、AppDelegate 启动观察器、系统 add 前后及 delegate 回调日志、新增 F2aObserver。MailState、AppState、MailNotificationCoordinator、通知路由及 UI 与原源码相同。真实 `LocalNotificationCenter.system` 的 add/remove/查询链保留，没有替换成 recorder。
- 观察器查询**本 bundle**的真实 UNUserNotificationCenter settings/delivered/pending，记录 dockTile 属性及 identity-only receipt；`system-events.jsonl` / `events-audit.json` 共 14 次生产 add、14 次成功，5 次真实 `UNNotificationDefaultActionIdentifier` 回调。截图只保留自身窗口、合成通知卡片或经 bundle URL 绑定的 Dock 图标；没有用整桌面/侧栏数字冒充系统证据。
- 首次系统返回 denied，未出现首次授权框；只打开本测试 bundle 的系统通知页并开启 Allow notifications，真实 settings 变为 authorized。最后关闭同一测试开关，不改正式 App、全局 Focus、TCC 数据库或其他 bundle。用户已提前知悉测试通知/权限设置。GUI 前检查 context，接近 40% 后收敛，不因摘要压缩后较低读数追加新 GUI 场景。

## 结果矩阵

| 项目 | 结果 | 实际证据与准确范围 |
|---|---|---|
| individual 投递 | 通过 | 02–04：UID161/162 两条真实 delivered，生产 add 成功、整批 ack、receipt handled；系统通知中心显示“合成发件人 / F2a 合成测试邮件”。02 请求日志正文 GET 为 0；通知协调器的 `/summary` 查询不能误计为正文下载。 |
| summary 投递 | 通过 | 06–08：UID171–174 合成批次只 add 一条“收件箱有4封新邮件”，系统 banner/center 可见。模式由 fixture 提供；不把 App 测试算作真实 IMAP 的 >3/10分钟后端分类验证。 |
| ack 失败、同批重连、跨进程去重 | 通过 | 06/09–11、`cross-process-result.json`：summary 成功但 ack 故意失败，pending 保留；实际点击使系统移除该条目后 receipt 仍保留。停止 PID93695→启动13235，add 总数3→3，不再投递；恢复 ack 后 pending 空。不是只凭稳定 identifier 判断，也不扩成 exactly-once/掉电保证。 |
| 正文可见同封抑制 | 通过 | 13→14：实际显示 UID159 纯文本正文，以 fixture read_fail 保持其未读，随后同封 arrival 不 add、整批 ack。不是仅选中/pending 路由抑制。 |
| Email 查看其他邮件与关窗投递 | 通过 | 15 的 UID164 真实 delivered/banner；16 关窗（AX 无窗口）后 UID165 仍真实投递，中心条目4。 |
| Messages→Email、页外单封真实点击 | 通过 | 05：物理点击真实 UID162 通知，delegate 回调，窗口转 Email，列表初始仅到160，页外 `/summary` 后加载162正文。 |
| 关窗后真实点击开窗口 | 通过 | 31：物理点击 UID260，真实回调后重开 Email 并显示目标。17 的早期点击工具没有回调，不用该轮冒充通过。 |
| 汇总真实点击 | 通过 | 09：真实回调转 Email/INBOX，不选择任意成员正文。 |
| 404 目标真实点击回退 | 通过 | 32：真实 UID261 通知仍在中心；hold_stream 暂停新状态，让 fixture 静默删除目标，再物理点击。delegate 回调与 `/summary` 请求关联，页面显示“这封邮件已不存在或已失效，已返回收件箱”，无错误正文。 |
| 410、旧账号真实点击 | 未验 | 404 不覆盖 UIDVALIDITY/账号失效路径；没有用直接调用 route 代替实际点击。 |
| 未知 intent 安全策略 | 通过，状态播种 | 18/18b：停止 App 后仅在自己偏好播种 handled=false、center 无匹配的 receipt，两轮启动 unknown=1，pending 留存，自动不 add、不 ack。AXPress“再次提醒”后真实 add/整批 ack，19/19b 与两个 `unknown-intent-*.json`。这是窄窗口状态注入，未真实制造崩溃。 |
| 未知提示布局 | **失败 P2** | 18/18b 最小800×512窗口（内容800×460）和980×680正常窗口，提示文字都与收件箱工具栏重叠，见下节；按钮可用，不能把逻辑成功覆盖布局失败。键盘 Tab/Return 未测。 |
| 已递送 read/delete/summary成员清理 | 通过 | 21→22 summary任一成员已读后移除整条摘要；22→23 read164/delete163精确清理；真实中心8→7→5，合成 chat 保留。包含有限 SSE 重连时按权威摘要恢复，未宣称所有丢事件竞态。 |
| reset/account remove 与命名空间 | 通过 | 24 reset 清邮件只留 chat；33→34移除账号清邮件，chat保留；35真实 chat 点击回 Messages，36中心空。`messages:`与`email:` identifiers 分域，没有全中心清空。 |
| 真正待递送 requests 清理 | 通过，系统请求播种 | 37 真正 UN 定时 requests 为4；38 read301/delete303后剩 email302+chat；39移除账号后只剩chat；40精确按自己identifier清理后0。四条1200秒请求由观察器播种，生产恢复/清理链执行；不声称产品正常使用定时通知。 |
| Dock 合计、0、99+、移除账号 | 通过 | 27–30真实 Dock 截图与同PID dockTile相符：聊天7+邮件5=12；0无角标；7+321=99+；移除邮件剩7。`*-dock-ax.txt` 使用独立bundle路径绑定图标，不拿侧栏代替。 |
| offline/auth_failed 旧计数 | 通过 | 25/26服务状态与App AX、同进程真实badge属性仍99+；29同一总数的Dock截图。没有为这两状态分别拍独立Dock画面，不声称真实断网/邮箱认证失败。 |
| 已拒绝权限下启动恢复 pending | 通过 | 42 / `permission-result.json`：系统authorization=denied，PID75129从既有pending启动，生产 add14→14、center空、stable-5成功ack，Dock99+。这是明确抑制，不是系统add失败。 |
| 稳定账号运行中关闭权限 | **未验；首轮断言失败保留** | 41 的失败混入 fixture 恢复已移除UUID，不能算有效权限切换测试；42不覆盖此项。准确归因见下节。 |
| 系统 add 失败/部分失败/再次提醒失败恢复 | 未验 | 14次真实add全成功；未故意破坏系统权限/数据库制造失败。E的recorders/失败注入仍只算自动证据。 |
| 升级前旧 chat_id 通知兼容 | 未验 | 本次chat使用当前typed格式，不能覆盖遗留payload。 |

## P2：未知提示与收件箱工具栏重叠

最小复现：在停止的隔离 App 偏好中播种正确账号/文件夹/UIDVALIDITY 的未确认 receipt，并在服务提供同批 pending；启动、打开 Email。真实 center 无该条目，未知提示显示。两轮分别使用最小与正常窗口，都看到“有1条邮件提醒的投递结果未确认”覆盖收件箱标题/工具栏区域。

18 的 AX 提示位置约 x789/y387/w194/h16，收件箱 menu x797/y387/w106/h24；PNG直接可见重叠。18b独立重建进程仍复现。影响：恢复提示与收件箱控件难以阅读，但“再次提醒”仍可按，真实投递/ack成功。严重度 P2，交协调者另派布局返修与独立复验；本 tab 未改 UI。

## 保留 disabled_check.py 初次失败及归因

`disabled_check.py` 原始执行在 PID65846 已移除账号后，关闭测试 Allow notifications，再调用 `/control/set {configured:true}`，以**同一个刚移除UUID**恢复配置并 arrive UID310/stable-5。前两断言（add不增加、真实center空）通过；`assert any(a['batch_id']==batch for a in r.ctl()['acks'])` 抛 AssertionError。41快照保留：authorization=1、receipt空、Dock7、后端pending含stable-5且无其ack。`disabled-initial-failure.json`转录失败位置并保留后端证据，未重新运行或覆盖原始快照。

不能将前两断言算成“运行中权限抑制通过”：当时 App 仍处未配置状态。服务在恢复后收到3次 `/mail/status` GET（约1791932029.16/2030.23/2031.30），所以不是没有HTTP恢复触发。代码依据：`MailState.removeLocalAccount` 将UUID加入当前进程 `retiredAccounts`；`apply` 和 `receive` 拒绝其状态/事件。正式 `MailService.configure` 在已移除账号后会生成新UUID，fixture的原地恢复不符合该契约。这足以解释41不消费pending及Dock7，归类为**fixture前置条件无效**，没有证据把它报成产品权限切换缺陷。

随后停止65846→启动75129，进程内retired集合重建，在已经denied的系统设置下消费相同pending并抑制/ack（42）。该轮仅验证拒绝权限下启动恢复，**不能自动覆盖41的失败，也没有补验稳定账号运行中的权限切换**。受context收敛要求，本次不再新增GUI；后续最小复验应保持一个从未移除的稳定配置账号，仅切自己bundle通知开关，再发新批次，关联settings/status/receipt/ack，而不是先移除再恢复旧UUID。

## 工具与未验边界

- 合成服务接续 E fixture，使用假 HTTP/SSE、假邮件状态，不运行真实IMAP/本机正式backend；SSE主要是有限流反复重连，因此请求数较高。新服务轮次会重置 generation、batch基数；旧App已到generation2时曾拒绝新服务generation1，重启隔离App后再开始第二轮，不能混合两轮计数判断产品丢事件。
- 早期固定坐标点击时钟/折叠stack工具失败；后用 ControlCenter 的 Clock AX 打开中心，并实际点击合成卡片，只有记录了真实delegate回调的05/09/31/32/35算点击通过。17仅开窗口/工具尝试不算通过。未读清理时不使用 removeAllDeliveredNotifications。
- chat fixture历史接口返回 `{messages,has_more}`，生产客户端要求数组，导致合成聊天正文加载失败；chat当前通知实际投递、点击切模块和邮件清理保留chat已有证据，**聊天正文/完整聊天回归不算通过**。此工具差异交F2b接续时修正，未顺手扩展回归。
- 未测真实崩溃的add/receipt/ack窄时序、掉电/损坏receipt、真实系统add部分失败，未知intent只播种对应可复现状态。真实Seen/跨端、真实新邮件来源、真实邮箱通知及长期IDLE仍需要指定测试邮件；合成不冒充接入。
- F2b继续实际SecItem/Debug–Release互访、supervisor生命周期/退出/唤醒、有限聊天回归、整体全量检查及安排后的实际睡眠。没有以本次外部fixture停止当作backend生命周期通过，没有让用户机器睡眠。

## 清理与提交

`final-own-center-empty.json`：退出前本bundle真实delivered=0/pending=0；精确清理chat待递送identifier，未碰其他bundle条目。停止自身App75129、fixture uv41142/python41143和caffeinate92826，18875无listener。删除本测试UserDefaults域及独立HOME/data，保留源码、截图、合成请求日志与身份注入证据。仅关闭标题匹配本测试的系统设置窗口，测试通知开关留关闭，OS测试bundle登记保留；未清用户全局授权/中心。

`cleanup.json`与`mac-dev-cleanup.log`记录清理；`mac-dev-cleanup --only browser --min-age 2`无浏览器资源可清，本次未启动浏览器或模拟器，不关闭其他会话。收尾脚本首次因ps显示fixture相对路径而安全断言退出，未kill进程；按实际命令核对后清理成功。

报告与必要known-issues/next-up/原计划/root及mac AGENTS状态同次提交，只提交文档；协调计划由coordinator维护，本tab未改。P2与未验项交回协调者，本tab停在F2a。

## 修改的文件

- 本报告：保存真实系统结果矩阵、P2最小复现、disabled初次失败和精确未验边界。
- `kb/known-issues.md`：登记未知提示布局P2，更新主要系统通知已验与剩余限制。
- `kb/next-up.md`：交接P2返修/独立复验、少量F2a余项和另派F2b。
- 原计划、根 `AGENTS.md` 与 `mac/AGENTS.md`：仅更新有证据的阶段状态，完整E/F组合项保持未完成。
- `tmp/` 工具与合成证据：不入版本控制；没有产品源码修改。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 已完整阅读，按当前F2a任务执行，未修改。
- [邮件阅读器计划](../plans/2026-10-13-email-reader-plan.md) — 通知/验收依据，仅更新有证据项。
- [E通知报告](2026-10-14-email-notifications-e.md) — 生产通知、receipt/ack、崩溃边界与合成入口依据。
- [D1配置报告](2026-10-13-email-configuration-d1.md)、[D2阅读器报告](2026-10-13-email-reader-d2.md) — wire/账号与正文可见契约。
- [F1b](2026-10-14-email-reader-f1b-acceptance.md)、[F1c](2026-10-14-email-reader-f1c-acceptance.md) — 隔离与既有UI验证边界；本次不重复其矩阵。
