# AGENTS.md

FeishuChat：不依赖飞书官方客户端的轻量飞书聊天客户端（macOS）。协议层走**逆向网页版协议**（cv-cat/LarkAgentX 的 `larkx` 包），不走官方 OpenAPI，因为公司租户是免费版，API 额度撑不起单聊的实时通知。选型依据见 `kb/notes/2026-09-29-feishu-chat-access-research.md`。

## 结构

- `backend/`：Python（uv）后端 `feishu-lite-backend`，封装 larkx，对外提供 127.0.0.1 上的 REST + SSE 接口，本地缓存用 SQLite。
- `mac/`：SwiftUI App `FeishuChat`（bundle id `com.reorx.FeishuChat`），负责拉起并守护后端子进程、界面和通知。工程约定和 App 的工作方式见 `mac/AGENTS.md`，改 App 之前先读。
- `kb/`：计划、笔记、session 总结；`kb/known-issues.md` 是已知问题的唯一清单，`kb/next-up.md` 是到期要做的检查。
- `tmp/`：探路脚本、验收脚本和截图，已 gitignore。

## 架构与后端生命周期

通信关系：`SwiftUI App ↔ 本机 REST + SSE ↔ Python backend ↔ 飞书网页版协议（HTTP + WebSocket）↔ 飞书服务器`。

- Python 是由 App 启动并守护的常驻本地服务子进程，负责登录凭证、飞书通信、实时连接与重连、消息同步和 SQLite 缓存；Swift 负责界面、本地通知和 Dock 角标。后端用 FastAPI + Uvicorn，仅监听 `127.0.0.1`，App 每次启动后端分配随机端口和访问 token。
- App 启动时拉起后端，关闭窗口后继续运行，退出 App 时终止后端；后端崩溃由 App 自动重启，App 异常退出则由后端检查父进程 PID 后自行关闭。它不注册为独立的 launchd daemon，也不会为每次聊天操作重新执行命令。
- Debug 通过 `uv run --project <backend目录> feishu-lite-backend --port P` 运行源码；Release 直接运行用户通过 `uv tool install` 安装的后端。`feishu-lite-backend login` 是额外的终端扫码排障命令，登录完成后退出。
- 本机服务就绪与飞书在线是两回事：后端连接状态为 `logged_out` / `connecting` / `online` / `reconnecting`；未登录或凭证失效时，本机服务仍运行，等待重新登录。生命周期入口见 `backend/src/feishu_lite/main.py`、`service.py` 和 `mac/FeishuChat/Services/BackendSupervisor.swift`。

## 当前状态

MVP 功能已经做完并通过验收：扫码登录、会话列表、历史消息和翻页、发文本、实时消息、本地通知、Dock 角标、开机启动。计划和验收清单在 `kb/plans/2026-09-29-feishu-chat-mvp-plan.md`，逐项的验收结果和证据在 `kb/sessions/2026-10-01-feishu-chat-app-and-acceptance.md`。

独立图片消息已实现缩略图、点击预览/缩放和失败重试；通过鉴权接口 `GET /messages/{message_id}/image` 按需下载，兼容旧缓存，不支持发送图片或富文本内嵌图片。自动测试和隔离界面验收通过，真实飞书下载待验证，详见 `kb/sessions/2026-10-06-image-messages.md`。

会话列表支持多选隐藏、隐藏列表和取消隐藏；偏好按账号保存在 App 的 UserDefaults，收到新消息不会解除隐藏，不改变未读和通知策略。验收见 `kb/sessions/2026-10-08-hidden-chats.md`。

Messages / Email 双模块外壳已实现并通过自动测试与构建，独立 UI 验收待办；Email 当前是待接入占位，IMAP 阅读器尚未实现。真实 IMAP 只读探路已通过，后端库选定 IMAPClient（实施阶段引入）；首版列出全部文件夹、仅读取收件箱，开发依据见 `kb/plans/2026-10-13-email-reader-plan.md`。实现 IMAP 前读 `kb/notes/2026-10-13-email-imap-probe.md`；接续 App 开发的实际接口与 B 验收交接见 `kb/sessions/2026-10-13-email-shell-phase-b.md`。

## 文档

- `kb/docs/module-shell.md` — 双模块的切换、已读、通知与 badge 规则；修改模块外壳或跨模块行为前读。

## 运行和测试

- CI 与发布：`.github/workflows/ci.yml` 验证测试、独立后端安装和 App 构建；`release.yml` 在推送 `vMAJOR.MINOR.PATCH` 时构建、签名、公证 Universal DMG 并发布到当前仓库。安装依赖和 Secrets 约定见 README「构建和发布」。Release 不内置 Python/larkx，安装命令固定到构建对应的 commit。

- 后端测试：`cd backend && uv run pytest`。App：`cd mac && make test && make build && make run`。
- App 自己拉起后端，不需要单独启动。正式数据在 `~/Library/Application Support/FeishuChat/`，后端日志在 `~/Library/Logs/FeishuChat/backend.log`。
- 接口约定以 `backend/src/feishu_lite/api.py` 和 `types.py` 为准；App 这边对应的模型在 `mac/FeishuChatCore/Sources/FeishuChatCore/Models.swift`，两边要一起改。

## 不变量

- larkx 只能以**固定 commit 的 git 依赖**引入，不要拷贝进仓库：上游没有 LICENSE。
- 测试和探路只能往用户指定的测试会话（群 **litetest**）发消息，不要往真实工作群发。
- 本人发的消息不计未读、不弹通知。测试需要"别人发的消息"时，用 litetest 里的自定义机器人：webhook 地址在 `tmp/bot-webhook`（不入库），`tmp/bot_send.sh <文本>` 发送。
- 会在用户屏幕上弹出通知或登录页的测试（比如用凭证副本测"登录已失效"），跑之前先告诉用户：它们和真的一模一样，用户会照着去扫码。
- 在 App 里打开一个会话会把它标成已读，手机上的未读也跟着清掉。用真实账号调试界面时只点测试会话。
- 提交进仓库的协议样本必须脱敏，替换人名、消息内容和各种 id。凭证绝不能进仓库。
