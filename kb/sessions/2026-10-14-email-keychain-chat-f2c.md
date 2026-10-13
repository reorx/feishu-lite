---
created: 2026-10-14
tags:
  - email
  - keychain
  - chat
  - acceptance
  - phase-f2c
---

# F2c：R4 真实双配置钥匙串隔离与限定合成聊天验收

## 概要

R4 可签收：最新生产 MailKeychain 源码在 Debug / Release 分别编译、以 Apple Development / Developer ID Application 签名，真实 file-based SecItem 对新随机同 UUID 的两配置条目独立读、改、删，缺失不回退，双 canary 保留，最终两 service × 4 UUID 共 8 个精确目标均确认缺失。没有系统密码授权阻塞，没有输入密码、修改 ACL 或访问历史用户条目。Release 兼容性仅证明本轮同 Release 签名新建的旧 service 条目，不覆盖历史不同签名 ACL。

限定聊天余项通过：稳定合成 SSE 下隐藏→隐藏列表选中→取消隐藏→主列表恢复；假扫码 waiting/scanned/success 和 logged_out/connecting/online；邮箱 auth_failed 与受控 HTTP request_timeout 期间聊天历史、实际键入后点击发送、模块草稿保留。聊天 Return 自动化未形成有效发送，本轮不签收该键盘路径；中文 IME、真实飞书/IMAP、真实睡眠以及既有精确边界仍未验。无新确认产品缺陷，不修产品、不委派、不扩展矩阵，整体 F 不宣称完成。

## 基线与隔离

- 当前 master，起始 HEAD `b87d2a5`，产品基线 `1f20f89`；只改 tmp 工具和本报告/状态文档，不修改协调文件，不 push/发布/新建分支或 worktree。
- 完整阅读协调文件「当前任务 F2c」、R4 五步交接、F2b 工具首败/隔离/剩余矩阵、根/mac AGENTS、桌面测试约定；另核对原计划、模块外壳与邮件基础文档。使用 kb 与 systools 技能。
- 全部证据和 23 张截图归档：`tmp/2026-10-14-email-reader/f2c-acceptance/`，gitignore。证据含 `keychain-results.json`、签名/strict 验证、真实清理、AX/截图/请求计数、最终源码 manifest/diff、资源记录；没有密码值、真实账号数据或原 env。
- helper 是当前源码副本的 SPM executable，使用副本 Makefile 的 `helper-debug` / `helper-release` 目标分别 `swift build -c debug/release`。没有以传入 service 字符串替代编译选择。`MailKeychain.swift` 与生产字节一致，SHA-256 见 `helper-production-source.json`。
- 两 helper bundle 均 `com.reorx.FeishuChat.f2c-keychain`，Team `YU3FMV36N2`、hardened runtime；Debug 实际 Apple Development，Release 实际 Developer ID Application，两 designated requirements 不同。`keychain-*-signature.txt` / `keychain-*-verify.log` 证明真实签名及 strict 验证。不是正式发行 App 的完整签名/公证验证。
- GUI 从最新源码另建 `com.reorx.FeishuChat.f2c-acceptance`，Apple Development 签名，独立 HOME/CFFIXED_USER_HOME/data/偏好，fake SecItem，直连 18875 合成服务。端口启动前确认空闲；不运行 make run，不改正式 bundle/签名、系统设置或用户 App。GUI 前 context 20%，收尾 29%，始终低于 40%；每次截图先 wake-screen，本轮 caffeinate 有限 1800 秒。
- GUI 副本仅改 bundle/显示名/本副本签名、fake SecItem 和只读 F2cObserver；observer 记录模块、两领域状态、安全错误及本 bundle 通知 IDs。UI、AppState/MessagesState/MailState、Composer 和通知调用链保持源码。最终差异见 `source-manifest-final.json` / `source-diff-final.patch`。

## R4 结果与真实 OS / harness 边界

| 项目 | 判定 | 证据与边界 |
| --- | --- | --- |
| 编译条件选 service / 真实签名 | 通过 | Debug ready=`com.reorx.FeishuChat.mail.debug`，Release ready=`com.reorx.FeishuChat.mail`；两个真实签名、strict 验证通过 |
| 仅 Debug 主 UUID 存在，Release notFound / 幂等删不影响 | 通过，真实 SecItem | Release 的生产默认 query；Debug 主条目和 canary 精确比较仍匹配 |
| 同 UUID 双侧独立随机密码 / 更新 | 通过，真实 SecItem | 每侧值由其常驻 helper 随机生成，只留内存；各自读取精确匹配自己的值，两侧分别更新后对方仍匹配 |
| 双向删除 / 缺失不回退 / canary | 通过，真实 SecItem | Debug 删除后 Release 主条目仍匹配，反向同样；双方缺失读与重复删不越 service，双 canary 保留 |
| Debug 缺失只提示重新输入、不注入 | 通过，真实 SecItem + 调用 harness | 同 state UUID 仅 Release 有值，production MailState 自动读一次，credentialIssue=notFound，两个 streamConnected 后 `/mail/account/credential` 为 0；提示“请重新输入专用密码” |
| 手动输入保存只写 Debug / 对方不变 | 通过，真实 SecItem + 调用 harness | `updateCredential` 一次合成 HTTP 注入、一条本 service write，读取匹配内存输入值；Release 同 UUID 仍精确匹配原值 |
| 延后删除失败跨 MailState 重建精确清理 | 通过，混合证据 | 单次 `.denied` 由 Counted wrapper 注入，不是真实 OS 拒绝；两个 service 的 pending UUID 均为本轮新条目。首删保留 pending，重建后生产删除 Debug 条目，Release 条目不变；偏好仅存 UUID |
| Release 旧 service 查询兼容 | 通过，限定真实 SecItem | 本轮 Release 签名自己创建并查询旧 service 条目；不访问旧 Debug / 用户已有条目，也不推断历史 ACL |
| 最终创建方逐 UUID 清理 | 通过，真实 SecItem | `keychain-cleanup.json`：Debug / Release 各 4 个 UUID 精确 delete 后 read=notFound，8 项 absent=true |

`keychain-results.json` 有 53 个 action 结果，包含逐步清理；不把每个 action 计作自动单测。两 helper 常驻 stdin JSON 指令只传动作/非秘密 UUID；每侧期望密码留在自身进程内存，stdout 只记录布尔匹配/service/安全错误。没有枚举钥匙串、copy 用户条目或把密码放进文件/日志/命令参数。helper 未替换 HOME，使用 OS 真实钥匙串；GUI 独立 HOME 不被当作物理 Keychain 隔离证明。

MailState 与 MailKeychain 为生产代码；HTTP 为 URLProtocol、ready/capability/SSE 为受控方法调用，不能据此声称真实后端恢复、IMAP 认证或完整启动链已验。单次删除失败为注入；真实 denied/locked UI 仍未验。本轮没有遇授权框或解锁路径，不靠授权成功取得隔离结果。

## 限定聊天与邮箱故障隔离

| 项目 | 判定 | 画面/请求证据 |
| --- | --- | --- |
| 隐藏完整往返 | 通过，真实 GUI + 合成聊天 | 01 checkbox 后“已选 1 项”→02 主列表空→03 隐藏列表目标可见→04 checkbox 后“已选 1 项”且取消隐藏 enabled→05 隐藏列表空→06 原列表恢复；`hide-result.json` |
| Email 下 logged_out 不启动 QR | 通过，合成状态 / 真实 GUI | 10 的 Email 页面仍可用，QR POST=0 |
| 合成扫码等待/已扫码/成功 | 通过，合成协议 / 真实 GUI | 11 真实渲染假测试码；12 已扫码/手机确认；13 登录成功等待连接；一条 `/login/qr` POST，没有真实登录请求 |
| connecting→online→历史恢复 | 通过，合成状态 / 真实 GUI | 14 observer connecting / 待连接页；15 连接状态在线；16 选择合成聊天后历史可见；`login-result.json` |
| 邮箱 auth_failed 期间聊天/草稿 | 通过，合成错误 / 真实 GUI | 20 实际 cliclick 键入草稿→21 Email“专用密码已失效”且 Return 不增加聊天 POST→22 返回草稿保持→23 物理鼠标发送，一条聊天 POST，self bubble 可见；发送时 observer mail=auth_failed、chat=online |
| 延迟 timeout 期间聊天/草稿 | 通过，受控 HTTP / 真实 GUI | 24a CG 实际 virtual key down/up 键入 `F2c-timeout-draft`，非 AX SetValue/Unicode 注入；24 Email 离线缓存，刷新发出 `/mail/sync?reconnect=false&wait=false`；返回 Messages 草稿保持，点击发送在请求起始后 0.474s 完成；3s 后服务返回 504 request_timeout，26 Email 显示安全超时提示；25/27 气泡/历史与 chat=online |
| 故障期间聊天 Return 发送 | 未验 | CG Return 与 cliclick Return 尝试没有形成 POST；有效发送证据均为实际键入+鼠标点击“发送”，不把按钮成功当作 Return 通过 |
| 中文 IME 组字 | 未验 | 只读 TIS 当前输入源为 ABC，不更改全局输入源/设置；实际键盘码 ASCII 不等于中文候选/markedText |

`final-control.json` 与 `evidence-summary.json` 关联请求时间：整轮 GUI `/events` 只有 1 次，持续心跳/动态事件，没有 F2b 的立即断流 reconnect 干扰；合成消息由 90→92，聊天发送 POST 恰好 2 次，QR POST 恰好 1 次。timeout 的聊天 POST 时间 1791936306.320019，mail sync 1791936305.8461592，确实在延迟 3 秒未返回期间完成，截图 25 的 mail_error 仍空；26 才显示超时。此处只证明本机 HTTP 与领域隔离，不代表真实 IMAP socket、服务停机、真实网络断开或机器睡醒。

## 首败、工具修正与自主决定

- `helper-debug-build-first.log`：工具 Swift 将 throwing read 放入 precondition autoclosure，编译失败；先把结果存局部值后才生成有效 helper。不改产品。
- `gui-build-first.log`：只读 observer 误用了不存在的 `selectedModule`；改成源码实际 `activeModule` 后副本 Makefile 构建成功。
- `gui-login-first.log`：断言假码应有 AX“登录二维码”节点失败。源码使用 decorative Image，AX 只暴露标题/说明；保留 11 截图并人工看图确认码，再接续已扫码/成功，不重新跑旧矩阵，也不报成二维码渲染缺陷。
- `gui-faults-first.log` / `gui-faults-continue.log`：恢复草稿后 Return 未增加 POST；继续 cliclick 的 `-send` 后实际文本变成 `F2c-s-auth-draft`，没有完整得到预期追加。保留 22a 截图/AX/control/focus，不能宣称有效完整键入或 Return 成功，也没有足够事件到达证据判定产品缺陷。23 最终实际鼠标发送的精确文本就是 `F2c-s-auth-draft`。
- `gui-faults-buttons.log`：auth 发送已通过，但下一步 cliclick timeout 文本未进入输入框，等待失败。期间测试窗口变为 fullscreen，resize 后 move 返回 -25200，几何假设不再有效；未确定其发生原因，不将它称为已确认产品缺陷。最后重新查实际焦点/几何，改用逐键 CG 虚拟键码得到完整 ASCII 草稿，`gui-timeout-final.log` 才有效完成 timeout 路径。没有调整全局设置或产品代码。
- 本轮目标要求实际键入发送；按钮发送满足这项，Return 自动化留未验，没有为得到全绿而改 Composer、delegate、状态或网络代码。没有选择新的 UI 矩阵、锁用户钥匙串、制造真实错误密码或新权限测试。
- 无新产品代码，不重复全量：引用 R4 的 Core74/App96、Debug/未签名 Universal Release 构建及 F2b 后端301。本次只新构建两配置 helper/GUI 副本、必要工具与独立证据审计；不跑 formatter/style linter。

## 定向清理

- 创建方 Debug / Release 各自对本轮 4 个新 UUID delete + read，8 service/UUID 组合 absent=true；helper 进程退出，密码随内存释放。不是扫描/删除所有 mail service 条目。
- 测试 App PID95800 正常退出；仅本轮 fixture 进程组 PID95788 和 caffeinate PID95789 终止；18875 无 listener，本轮 helper/App/fixture 存活数 0。
- 本测试 bundle delivered/pending 通知均为空；无新通知投递、scheduled 请求或通知权限设置操作，不清用户中心。未启动浏览器/模拟器。
- 本轮 GUI 偏好域删除并确认不存在，精确测试 bundle plist 和唯一 `f2c-state-<UUID>` harness plist 已清理，harness 前缀残留 0；独立 home/data 删除。保留日志、截图、脚本、源码副本和编译产物，不执行全局 make clean。
- `mac-dev-cleanup --only browser --min-age 2` dry-run/实际均 nothing to clean，没有关闭他人浏览器/模拟器/正常 App。清理证据见 `resource-cleanup.json`、`center-cleanup.json`、`cleanup-first.log`、`browser-cleanup*.log`。
- `evidence-audit.log` 独立复核 8 个缺失目标、1 条稳定 SSE、2 次发送/92 条消息、超时请求内发送时间及偏好无残留，通过；初始工作区干净，仅提交自己的文档。

## 修改的文件

- 本报告：R4 判定、真实/harness 矩阵、有限聊天结果、首败和清理。
- 根/mac `AGENTS.md`、README、`kb/docs/email-foundation.md` / `module-shell.md`：替换已过期的“新 service 真实复验待做”与有限聊天未验状态，保留历史 ACL / 系统错误 / 真实邮箱 / 其他边界。
- `kb/plans/2026-10-13-email-reader-plan.md`：只补有证据的 R4/F2c 子项，D/E/F 完整组合项保持未勾选；协调文件不改。
- `kb/known-issues.md` / `next-up.md`：移除已完成 R4 最小复验待办、缩小 GUI 待验范围；没有新增确认产品缺陷，也不动用户 todo。

## 遗留问题

1. 历史不同签名旧共享条目的 ACL、真实拒绝/锁定 UI 与正式发行 App 授权仍未验；本轮成功不承诺历史授权框消失，也不迁移历史条目。
2. 中文 IME、故障期间 Return 发送的可靠事件证据仍未验；现有失败不足以归因为产品，若协调者接续，最小范围应记录 native event/markedText/focus 与请求时间，不通过扩大键盘矩阵或修改产品绕过。
3. R3 Tab/Return、F2a 运行中权限切换/旧 payload/410/部分真实 add 失败、未知能力/旧导航及已发 STORE 身份变更竞态未扩展，维持原报告边界。
4. 真实邮箱 Seen/跨端 flags、新信/来源、真实断网与长期 IDLE/机器睡眠仍须协调者安排并由用户指定目标，不以合成窗口取代，不打开真实工作邮件。

## 已完成的待验事项

R4 新配置 service 的真实 OS 隔离及其最小恢复/清理交接完成；限定隐藏取消、合成扫码状态与邮件错误期间聊天/草稿完成。known-issues 的组合条目只缩小范围，未整条删除；无本轮修复产品缺陷。

## 相关文档

- [协调任务 F2c](../plans/2026-10-13-email-reader-coordination.md) — 本次授权及边界，只读不改。
- [邮箱阅读器计划](../plans/2026-10-13-email-reader-plan.md) — 更新证据子项，完整 F 保持未完成。
- [R4 实现报告](2026-10-14-email-keychain-services-r4.md) — 本次五步独立复验依据。
- [F2b 报告](2026-10-14-email-system-integration-f2b.md) — 工具首败、旧 service 密码阻塞、GUI 最小接续及基线检查。
- [F2a 报告](2026-10-14-email-system-notifications-f2a.md)、[F1c 报告](2026-10-14-email-reader-f1c-acceptance.md) — 系统精确边界和中文 IME 等未验保持原范围。
- [邮件基础](../docs/email-foundation.md)、[模块外壳](../docs/module-shell.md)、[Known issues](../known-issues.md)、[Next up](../next-up.md) — 同步当前事实与后续边界。
