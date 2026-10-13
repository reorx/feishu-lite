---
created: 2026-10-14
tags:
  - email
  - acceptance
  - keychain
  - lifecycle
---

# F2b：R3、测试 UUID SecItem 与隔离集成验收

R3 的提示与收件箱工具栏重叠 P2 可以关闭。最新源码隔离副本在最小内容 800×460、正常窗口、配置/正文/模块重建、2048 条计数及实际两行换行时均不重叠；鼠标再次提醒走真实系统中心与合成后端 ack。Tab/Return 未形成有效按钮焦点，仍未验。

真实 file-based SecItem 的 Debug、Release 各自 CRUD/canary 通过；Debug 创建条目后 Release 互访被 login 钥匙串密码授权阻塞，20 秒超时，不能签收跨签名互访，也不能用单构建成功替代。真实生产 Supervisor 的隔离后端关窗常驻、崩溃重启和退出清理通过。全量首轮后端 301、Core 74、App 92 项及 Debug 构建通过。F 整体仍未完成，不含真实 IMAP/跨端 Seen/真实机器睡眠。

## 基线与隔离

- 当前 master，开始 HEAD `98b6bce45e6ababbee8eb8244cedefb79f249256`，R3 产品基线 `e22d1a9`；只修改 tmp 工具与文档，不改产品、协调计划，不建分支/worktree，不 push/发布，不自行委派。
- 已读协调文件「当前任务 F2b」及根/mac AGENTS、桌面测试约定、原计划 §7、D1、E、F2a、R3、B 验收与 F1c 剩余边界；使用 kb 与 systools 技能。
- 证据和截图均在 `tmp/2026-10-14-email-reader/f2b-acceptance/`。该目录被 gitignore；保留源码副本、脚本、截图、AX、日志、签名与清理结果，合成账号密码没有写入文件或报告。
- GUI bundle `com.reorx.FeishuChat.f2b-acceptance`，Apple Development 签名，独立 HOME/data/偏好；GUI 使用 fake SecItem 和 18875 合成 HTTP/SSE。没有读真实 env、正式缓存、工作邮件或聊天，没有真实扫码或发消息。
- GUI 副本差异包括 bundle/名称/签名/后端目录、fake SecItem、系统通知 add/delegate 观察点、F2bObserver，以及仅测试的字号环境注入。生产通知 coordinator/router、阅读布局与 Supervisor 保持原源码。最终差异见 `source-manifest-final.json`、`source-diff-final.patch`，初始 manifest 不能代表后续全部工具差异。
- 生命周期使用 `CFFIXED_USER_HOME` 配合 HOME/data，将 Cocoa 后端日志也隔离；没有邮箱或聊天登录配置。helper 与 GUI 副本分开，helper 的 `MailKeychain.swift` 与当前生产源码字节一致。

## 结果矩阵

| 项目 | 判定 | 真实与模拟边界 / 证据 |
| --- | --- | --- |
| R3 最小/正常尺寸、配置、正文、模块重建 | 通过 | 真实 App 窗口与 AX；02–06 截图，`r3-geometry.json` |
| 长计数及两行换行 | 通过 | 2048 个合成 pending/identity receipt；09/10 正常字号，15 仅副本 48pt 环境压力测试 |
| 鼠标再次提醒→提示消失、布局恢复 | 通过 | 真 UNUserNotificationCenter add；合成 UID400 与 ack；07、`r3-mouse-result.json` |
| Tab/Return 再次提醒 | 未验 | 12 次 Tab 焦点仍为窗口；不改系统 Keyboard Navigation；`r3-keyboard-result.json` |
| Debug 自身真实 SecItem CRUD/canary | 通过 | 随机测试 UUID、仅内存随机密码；`keychain-Debug-crud-crud.log` |
| Release 自身真实 SecItem CRUD/canary | 通过 | Developer ID 签名 Release helper；`keychain-Release-crud-crud.log` |
| Debug→Release 真实互访 | 阻塞、未验 | password 授权窗口 + 20s TimeoutExpired；`prompt-check.txt`、`interop-timeout.json` |
| Release→Debug 互访、真实拒绝/锁定错误 UI | 未验 | 未继续需密码的路径；D1/F1b 模拟错误证据不能升级为真实通过 |
| 启动读一次、ready+SSE 后注入、重启复用内存 | 通过（调用 harness） | 真 SecItem + production MailState；HTTP/ready/SSE 事件合成；`keychain-Debug-state-state.log` |
| 外部模式不自动读/注入、canary 不被访问/清掉 | 通过（调用 harness） | 一次主 UUID read、外部模式 read=0、canary 保持可读；非真实 IMAP |
| HOME 物理隔离同一 OS Keychain | 不作此结论 | 两个替换 HOME 的 no-UI 查询为 notFound；原因未确定，不是物理隔离证明 |
| 关窗常驻、杀自己的后端自动重启、退出清理 | 通过 | 真生产 Supervisor + 真 Python 后端，空配置；20–22、`lifecycle-results.json` |
| 唤醒入口合并重连 | 通过（合成事件） | 测试进程内 NSWorkspace 通知 100 次，仅 1 次 reconnect sync、0 QR；`wake-result.json` |
| 聊天历史数组、分页、实际键入发送、图片预览 | 通过（合成服务） | 90 条历史、before_position=61、一次 POST/91 条消息、合成 PNG；30/35–37 |
| 草稿及 Email Return 不发聊天 | 通过（有限合成路径） | 31 与 control POST 计数；AX 草稿，不代表中文 IME |
| 隐藏 / 取消隐藏完整往返 | 部分、未验 | 41 checkbox→42 主列表消失、管理菜单显示隐藏 1；取消隐藏未形成有效选中证据 |
| 扫码显示/登录态切换、邮箱认证/超时期间聊天 | 未验 | fixture 已支持，但按 coordinator 收尾指示不再展开 GUI |
| 运行中权限切换、旧 payload、410/旧账号点击、真实 add 部分失败 | 未验 | 不扩展可选项；F2a 已有证据维持原准确范围 |
| 全量与 Debug 构建 | 通过 | 首轮 301/74/92，Build Succeeded，无循环复跑 |

## R3 签收依据

准确最小窗口证据为 02：外窗 800×512，内容 800×460。提示标题 y161/h16，说明 y181/h13，按钮 y165/h24；阅读 split 从 y207 开始，收件箱工具栏 y227/h24。03/06 为外窗 980×680。配置、正文 UID159、Messages→Email 重建后提示仍在独立行。01 是尺寸尚未稳定的 889×595 过渡取证，不能当精确最小证据。

09/10 的 2048 条长计数正常字号仍为单行。13 的 28pt、14 的 36pt 也未实际换行；真正两行证据是 15 的 48pt：标题 y161/h112，说明 y277/h13，按钮 y213/h24，split y303，工具栏 y323/h24，剩余阅读区 306pt。截图完整显示文字与按钮，列表可见。这里注入的是测试副本字体，没有改全局系统字号，不能声称真实全局 Dynamic Type 设置已验。

07 的实际鼠标点击使 production add-success 从 0→1，系统 delivered 中出现合成 UID400，后端 ack 清 pending，提示消失。2048 条压力批次没有点击再次提醒，未制造大量系统通知。unknown receipt 是 App 停止时播种的身份记录，不是实际制造崩溃。

键盘第一尝试复用了 stable-1/UID400，此时中心已有条目，被生产恢复精确确认并 ack，不能作 unknown 键盘证据。随后改为 stable-2/UID600，pending 确为 1，12 次 Tab 均没有得到按钮焦点。保留尝试，结论为未验。布局 P2 关闭不代表按钮键盘及整个 F2 全部通过。

## 真实 SecItem、签名和授权阻塞

测试 helper bundle 均为 `com.reorx.FeishuChat.f2b-keychain`，Team `YU3FMV36N2`，hardened runtime；Debug 为 Apple Development，Release 为 Developer ID Application，实际由 Debug/Release 两种 configuration 编译。`keychain-*-signature.txt` 保留证书链和 designated requirement，`keychain-*-verify.log` 的 strict 验证通过。两者 requirement 不同，这不是两份同签 helper，也不是正式发布 App 的完整互访验收。

每个自身 CRUD 验证缺失→写→精确比较读取→更新→精确比较读取→删除→缺失；删主 UUID 后独立 canary 仍能精确读取，再删 canary→缺失。密码由 UUID 随机生成，只留进程内存。生产 query 为固定 service `com.reorx.FeishuChat.mail` + 精确 account UUID，没有 data-protection/access-group/synchronizable 设置，也没有 HOME 前缀。

Debug 创建 interop_debug 主/canary 后，Release 的 read-no-ui probe（copy 查询附加 `kSecUseAuthenticationUIFail`，不修改 ACL）20 秒超时，subprocess.run 终止该 helper。SecurityAgent 实际提示测试 helper 访问“FeishuChat 邮箱”，并要求输入 login keychain password。没有输入或读取密码，没有解锁/锁住整个钥匙串，没有 Always Allow 或放宽 ACL；只对匹配本 helper 的窗口点 Deny。创建方 Debug 在 finally 精确删除并确认缺失，最终又核查了全部 UUID。

`interop-results.json` 只含创建/清理成功记录，不能隐藏中途 timeout。`interop-timeout.json` 是依据原执行输出与保留授权 AX 补记的结果，不是复跑。反向 Release→Debug 未执行；名为 interop_release 的 UUID 之后用于 Debug 创建的 HOME 探路，不能据此冒充反向互访。原计划 §D 明确互访会弹授权框就按构建 configuration 区分 service 名；本次不同签名的授权框已触发该既定后续实现条件，由协调者下一阶段处理 configuration service 隔离，无需等待用户密码。本 tab 只记录当前互访阻塞与证据，不修产品，也不把授权后可访问猜测当通过。

production MailState 调用 harness 真读取 state 主 UUID 一次；ready/capability 后、streamConnected 前不注入，两次 streamConnected 仅首次注入；backendChanged 后复用内存再次注入，共 2 次注入仍只有 1 次 Keychain 读取。externalBackend=true 读/注入为 0，canary 保持可读。HTTP 用 URLProtocol，ready/SSE 是受控调用，不代表实际网络连接/邮箱认证完成。

两个替换 HOME/FEISHU_LITE_HOME 的 no-UI 查询返回 notFound，未确定是搜索上下文还是其他条件，不以此证明 OS 钥匙串被 HOME 物理隔离。配置身份驱动精确 UUID、未触及 canary 的调用证据才是此次隔离结论；安全边界仍要求独立 UUID、fake GUI Keychain 或受控真实测试条目，不能只靠 HOME。

## 生命周期、聊天与首败

生命周期最终 round3：端口 65264 就绪，AX close 后窗口消失但 backend 仍 ready；仅 SIGKILL 本实例 Python child 后自动重启到 65290；quit App 后其全部子进程结束，两端口无 listener。后端日志位于 supervisor-home，data 只产生隔离 cache.db/larkx/mail.db。空配置不覆盖已登录 IMAP 守护；父异常退出的其他场景引用 C3b 原有时限证据，没有再次制造。

保留工具首败，不当作已通过步骤，也没有为全绿无因重复：

- helper 编译首两轮为 tmp Swift 空格/throwing autoclosure 问题，修正工具后才得到有效 helper，原 `helper-build*.log` 保留。
- 生命周期 round1 的 Cmd-W 被授权窗口抢焦点；round2 读到上次 observer ready/PID，子进程断言失败。round3 改为等待新 PID 并 AX close 自己窗口，`lifecycle-round2.log`、`lifecycle-round3.log` 保留；round1 错误见原工具输出，未另伪造日志。
- `integration-first.log` 中 AX set-draft 后 CG Return 没形成一次发送，不能证明产品发送错误或有效发送成功。补验实际 cliclick 键入/Return后一次 POST，self bubble 可见且 composer 清空。实际合成文本因光标位置拼接为 `F2b-syF2b-physical-sendnthetic-draft`，不是声称完整中文组字。
- 38–40 的管理勾选无效，隐藏按钮 disabled，文件名含 hidden 不代表隐藏通过。41 正确 AX checkbox 后 42 才实际隐藏；收尾 43/44 没有可靠取消隐藏证据，`44-chat-restored` 只是工具命名，结果仍未验。finite SSE fixture 立即结束流，截图多处显示 connecting；其与恢复失败的具体因果未隔离，不报已确认产品缺陷。
- 收尾误尝试再启动 fixture 被 18875 占用，`fixture-resume.log` 保留 Errno48；实际原 fixture 仍存在，没有并行第二个服务。settings 清理 Swift conditional CF downcast 编译首败保留 `settings-cleanup-first.log`，仅修工具后完成关闭自己的设置窗口。

37 屏幕出现更早历史，control 记录 `GET /chats/f2a-chat/messages?limit=30&before_position=61`。图片为本地合成 PNG。唤醒是测试进程内向 NSWorkspace center post 100 次，不是机器真实睡眠，也不能证明实际睡醒没有 Keychain 读取。

coordinator 在 context 约 37% 时要求收尾。压缩后检查显示 4%、最终 GUI 收尾检查 8%（`context-final-gui.txt`），没有因此扩展权限切换/旧 payload 等新场景；仅尝试完成已在进行的隐藏路径和必要清理，扫码等保留未验。

## 全量与交付审计

| 本次首轮命令 | 结果 | 日志 |
| --- | --- | --- |
| `cd backend && uv run pytest` | 301 passed，48.08s | backend-full.log |
| `cd mac && make test` | Core 74 + App 92 passed | mac-full-test.log |
| `cd mac && make build` | Debug Build Succeeded | mac-build.log |

R3 曾记录的 SSE `/mail/status <= 2` 偶发失败本次首轮没有复现；不因此宣称绝无 flake，也没有全量循环复跑。原始 R3 首败仍保留在其报告与证据目录。无新确认产品缺陷需本轮返修。

核对 CI 的 wheel build→uv tool install→CLI help，以及 Debug/Universal Release 构建约定；README 的 Release 依赖固定 commit 安装说明与现有部署流程一致。独立 wheel 安装沿用 C3b 已有证据，本次没有重新安装用户工具或发布。本次 typed/wire 与错误/SSE API 由全量自动测试覆盖；有限 GUI 历史 fixture 已修为生产 `/chats/{id}/messages` 数组契约。README、根/mac AGENTS、原计划和邮件基础文档同步精确状态，组合项及真实邮箱标准不全勾。

## 未验与最小接续

1. 不同签名互访已观察到授权框，触发原计划 §D 的 configuration service 隔离实现条件；协调者下一阶段按原计划处理，再安排对应验证，无需等待用户密码。本 tab 不改产品；当前反向互访、真实拒绝/锁定和正式发行 App 授权仍未验。
2. 若继续有限 GUI，仅补稳定合成连接下隐藏取消/扫码状态，以及邮箱 auth_failed/timeout 不影响聊天；R3 Tab/Return 在用户现有键盘设置允许时取证，不强改全局设置。真实中文 IME 仍沿用 F1c 未验。
3. F2a 运行中权限切换、旧 payload、410/旧账号与系统部分 add 失败，以及 F1 精确 navigation/layout/STORE 竞态按原报告最小范围接续，不能用本次自动全绿代替。
4. 真实测试邮件、发件来源仍未指定：跨端 Seen/FLAGS、真实新信与通知分类、长期 IDLE、真实邮箱断网及机器睡醒继续未验，不能打开工作邮件代替。

## 定向清理

- 最终按 `keychain-ids.json` 的 4 对、共 8 个 UUID 调用 production delete，再逐 UUID read 验证 notFound；全部 absent=true，含超时 helper 创建的主账号/canary。`keychain-final-cleanup.json` 保留每对结果，没有枚举用户钥匙串。
- 真实 center 只查询本测试 bundle，精确 IDs remove，delivered/pending 最终均空，`center-cleanup.json`。测试权限恢复到初始 Allow notifications=0，自己的设置窗口关闭（AX return0），`settings-final-cleanup.log`；不改正式 bundle 权限。helper 密码框先前只 Deny 自己窗口，最终定向检查无本 helper prompt。
- 测试 App 已退出，fixture uv/Python 与本次 caffeinate PID89404 已结束；18875、65264、65290 均无 listener，Supervisor 后代为空。其他 caffeinate/用户 App 未触碰。
- home/data、supervisor-home/data、keychain-home-a/b 已删除；测试 bundle 偏好域和对应 plist 删除并验证域不存在，MailState harness suite 由 defer 删除。日志、截图与源码差异保留。
- 未启动浏览器/模拟器。执行 `mac-dev-cleanup --only browser --min-age 2`，dry-run/实际均 nothing to clean；未广泛关闭用户浏览器或模拟器。详情见 `resource-cleanup.json`、`browser-cleanup.log`。

报告和必要文档同次提交；最终 commit 由执行者回报。协调者据此关闭 R3 布局 P2，保留整体 F 未验边界。
