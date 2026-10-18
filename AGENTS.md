# AGENTS.md

FeishuLite：不依赖飞书官方客户端的轻量飞书聊天客户端（macOS）。协议层走**逆向网页版协议**（cv-cat/LarkAgentX 的 `larkx` 包），不走官方 OpenAPI，因为公司租户是免费版，API 额度撑不起单聊的实时通知。选型依据见 `kb/notes/2026-09-29-feishu-chat-access-research.md`。

## 结构

- `backend/`：Python（uv）后端 `feishu-lite-backend`，封装 larkx，对外提供 127.0.0.1 上的 REST + SSE 接口，本地缓存用 SQLite。
- `mac/`：SwiftUI App `FeishuLite`（bundle id `com.reorx.FeishuLite`），负责拉起并守护后端子进程、界面和通知。工程约定和 App 的工作方式见 `mac/AGENTS.md`，改 App 之前先读。
- `kb/`：计划、笔记、session 总结；`kb/known-issues.md` 是已知问题的唯一清单，`kb/next-up.md` 是到期要做的检查。
- `tmp/`：探路脚本、验收脚本和截图，已 gitignore。

## 架构与后端生命周期

通信关系：`SwiftUI App ↔ 本机 REST + SSE ↔ Python backend ↔ 飞书网页版协议（HTTP + WebSocket）↔ 飞书服务器`。

- Python 是由 App 启动并守护的常驻本地服务子进程，负责登录凭证、飞书通信、实时连接与重连、消息同步和 SQLite 缓存；Swift 负责界面、本地通知和 Dock 角标。后端用 FastAPI + Uvicorn，仅监听 `127.0.0.1`，App 每次启动后端分配随机端口和访问 token。
- App 启动时拉起后端，关闭窗口后继续运行，退出 App 时终止后端；后端崩溃由 App 自动重启，App 异常退出则由后端检查父进程 PID 后自行关闭。它不注册为独立的 launchd daemon，也不会为每次聊天操作重新执行命令。
- Debug 通过 `uv run --project <backend目录> feishu-lite-backend --port P` 运行源码；Release 直接运行用户通过 `uv tool install` 安装的后端。`feishu-lite-backend login` 是额外的终端扫码排障命令，登录完成后退出。
- 本机服务就绪与飞书在线是两回事：后端连接状态为 `logged_out` / `connecting` / `online` / `reconnecting`；未登录或凭证失效时，本机服务仍运行，等待重新登录。生命周期入口见 `backend/src/feishu_lite/main.py`、`service.py` 和 `mac/FeishuLite/Services/BackendSupervisor.swift`。

## 当前状态

MVP 功能已经做完并通过验收：扫码登录、会话列表、历史消息和翻页、发文本、实时消息、本地通知、Dock 角标、开机启动。计划和验收清单在 `kb/plans/2026-09-29-feishu-chat-mvp-plan.md`，逐项的验收结果和证据在 `kb/sessions/2026-10-01-feishu-chat-app-and-acceptance.md`。

独立图片消息已实现缩略图、点击预览/缩放和失败重试；通过鉴权接口 `GET /messages/{message_id}/image` 按需下载，兼容旧缓存，不支持发送图片或富文本内嵌图片。自动测试和隔离界面验收通过，真实飞书下载待验证，详见 `kb/sessions/2026-10-06-image-messages.md`。

视频会议邀请显示主题、公开会议号和可点击的 `https://vc.feishu.cn/w/<meetNumber>` 入口；完整协议模型的 `meetNumber` 才是会议号，不能用内部 `meetingId` 代替。旧占位缓存在 feed 同步或历史读取时补全，详情不可用时每个后端进程只尝试一次；实现与验证见 `kb/sessions/2026-10-14-meeting-invitations.md` 和 `kb/sessions/2026-10-14-meeting-entry-links.md`。

会话列表支持多选隐藏、隐藏列表和取消隐藏；偏好按账号保存在 App 的 UserDefaults，收到新消息不会解除隐藏，不改变未读和通知策略。验收见 `kb/sessions/2026-10-08-hidden-chats.md`。

Messages / Email 双模块和单邮箱阅读器已实现并完成验收：列出全部文件夹、只读收件箱、100/50 分页、原生详情与隔离 HTML、可见性已读、持久通知批次与 ack、钥匙串配置。真实账号的接入与浏览、隔离 UI/WebKit 安全与竞态、真实系统通知与 Dock、Debug/Release 钥匙串隔离都有独立报告，已读双向同步和正常钥匙串下的重启恢复由用户手动验证；真实新邮件提醒、断网/睡眠恢复仍未在真实环境验证，见 `kb/known-issues.md`。验收汇总见 `kb/plans/2026-10-17-email-reader-finish-coordination.md`，范围见 `kb/plans/2026-10-13-email-reader-plan.md`；实现 IMAP 前读 `kb/notes/2026-10-13-email-imap-probe.md`，App 接续先读 C3b、D1、D2、E 的 session（wire、错误、重启、显示契约）。

2026-10-18 按[全界面 UI 审查](kb/reviews/2026-10-17-ui-review.md)完成了 32 条返修，并做了独立复验：去掉自绘导航列，模块切换并入系统侧栏；两个模块共用侧栏头部和提示条组件；邮件阅读器和聊天的排版、错误与空态都改过。会话详情偶发卡死已修好，代价是消息列表不再懒加载（见 `kb/known-issues.md`）。协调记录和各任务总结见 `kb/plans/2026-10-18-ui-fixes-coordination.md`。改界面前先读 `mac/AGENTS.md` 里的布局约束：分栏里不要用 `fixedSize(vertical:)`；消息详情保持普通 `VStack`；会换行的多行头部用 `TopDownStack`。

邮件实现的不变量：SQLite/emit 只在事件循环线程使用，IMAP/MIME 工作线程不能访问 Store；DNS stop_timeout 后必须等待旧所有者 closed 才新建网络实例；后端密码只留内存，正文 GET 没有已读副作用，邮件错误不使用聊天 409；页外路由用鉴权 `GET /mail/messages/{id}/summary` 取缓存摘要，不联网、不写 Seen；正文可见证据来自 `mail.displayedBodyRoute`，不是 pending 或裸选择；未知通知 intent 不重弹、不 ack，保留 pending 并提供明确的再次提醒入口。Debug 与 Release 用不同的钥匙串 service（Release 保留旧 service），缺失时要求重新输入，不回退、不迁移；密码写失败只留 App 内存，旧条目删除失败只持久化账号 id，以便重建后精确重试。

## 文档

- 改名兼容：数据目录和邮件 Keychain service 保留 FeishuChat 存储标识；UserDefaults 在模型创建前一次性迁移。新 bundle 的通知/登录项须重新授权，详见发布指南的升级说明。
- `kb/docs/releases.md` — 签名、公证、GitHub Releases 与 Homebrew Cask；修改发布工作流或执行发布前读。
- `kb/docs/module-shell.md` — 双模块的切换、已读、通知与 badge 规则；修改模块外壳或跨模块行为前读。
- `kb/docs/email-foundation.md` — 邮件账号、同步/提醒、独立缓存和正文安全边界；修改邮件服务、存储、解析或展示前读。

## 运行和测试

- CI 与发布：`.github/workflows/ci.yml` 验证测试、独立后端安装和 App 构建；`release.yml` 在推送 `vMAJOR.MINOR.PATCH` 时构建、签名、公证 Universal DMG，发布到当前仓库并更新 `reorx/homebrew-tap` 的 `feishu-lite` Cask。Release 不内置 Python/larkx；Cask 安装/升级时通过 uv 安装构建对应 commit 的后端。Secrets、首次发布和失败重试见 `kb/docs/releases.md`。

- 后端测试：`cd backend && uv run pytest`。App：`cd mac && make test && make build && make run`。
- App 自己拉起后端，不需要单独启动。正式数据在 `~/Library/Application Support/FeishuChat/`，后端日志在 `~/Library/Logs/FeishuLite/backend.log`。
- 聊天接口以 `backend/src/feishu_lite/api.py` 和 `types.py` 为准；邮件接口/共享模型在 `mail/api.py`、`mail/types.py`。App 聊天模型在 `mac/FeishuLiteCore/Sources/FeishuLiteCore/Models.swift`，邮件模型在同目录 `MailModels.swift`，合成 wire 样本由 Core 测试交叉验证；改已接入接口时两边要一起改。

## 不变量

- larkx 只能以**固定 commit 的 git 依赖**引入，不要拷贝进仓库：上游没有 LICENSE。
- 测试和探路只能往用户指定的测试会话（群 **litetest**）发消息，不要往真实工作群发。
- 本人发的消息不计未读、不弹通知。测试需要"别人发的消息"时，用 litetest 里的自定义机器人：webhook 地址在 `tmp/bot-webhook`（不入库），`tmp/bot_send.sh <文本>` 发送。
- 会在用户屏幕上弹出通知或登录页的测试（比如用凭证副本测"登录已失效"），跑之前先告诉用户：它们和真的一模一样，用户会照着去扫码。
- 在 App 里打开一个会话会把它标成已读，手机上的未读也跟着清掉。用真实账号调试界面时只点测试会话。
- 提交进仓库的协议样本必须脱敏，替换人名、消息内容和各种 id。凭证绝不能进仓库。
