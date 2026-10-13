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

Messages / Email 双模块外壳已实现并通过自动测试与构建；独立隔离 UI 已验证草稿、两处首可见行恢复、键盘隔离和模拟聊天回归，系统通知与部分完整回归仍未验，见 `kb/sessions/2026-10-13-email-shell-b-acceptance.md`。Email 配置、试连、精确账号钥匙串与重启恢复见 `kb/sessions/2026-10-13-email-configuration-d1.md`；主要配置 UI 已经 F1 隔离验证；真实 SecItem 和 Debug/Release 授权留 F2。D2 已实现收件箱 100/50 分页、原生详情、隔离 HTML 与成功显示后的可见性已读，通过自动测试和 Debug 构建；F1 已验证主要阅读 UI、实际 WebKit 资源/脚本隔离、HTTP/_blank 外开和可见性已读，HTML 切模块丢失滚动位置（P2）已完成 R1 自动返修，屏幕落点及新增内存文档隔离待独立复验，见 `kb/sessions/2026-10-14-email-html-scroll-r1.md`；浅色/拖宽/旧 cursor 完整恢复及部分竞态仍待接续；完整矩阵见 `kb/sessions/2026-10-14-email-reader-f1-acceptance.md`。实现接续先读 `kb/sessions/2026-10-13-email-reader-d2.md`。真实 IMAP 只读探路已通过，后端库使用 IMAPClient；首版列出全部文件夹、仅读取收件箱，开发依据见 `kb/plans/2026-10-13-email-reader-plan.md`。实现 IMAP 前读 `kb/notes/2026-10-13-email-imap-probe.md`。

邮件后端已接通独立 mail.db、MailService、全部 `/mail/*` API、双领域 SSE 和进程生命周期；App 已接通知投递/ack、精确清理、点击路由与唤醒重连，通过隔离自动测试和 Debug 构建，系统投递/点击/实际睡眠仍待 F2。E 接续与崩溃窗口见 `kb/sessions/2026-10-14-email-notifications-e.md`：成功 receipt 去重；未知 intent 不重弹、不 ack，保留 pending 并提供明确再次提醒入口。页外路由可通过鉴权 `GET /mail/messages/{id}/summary` 取得当前缓存摘要，不联网或写 Seen；正文可见证据来自 `mail.displayedBodyRoute`，不是 pending 或裸选择。SQLite/emit 只在事件循环线程使用，IMAP/MIME 工作线程不能访问 Store；App 接续先读 C3b、D1 和 D2 报告的 wire/错误/重启/显示契约。DNS stop_timeout 后必须等待旧所有者 closed 才新建网络实例；后端密码只留内存，正文 GET 没有已读副作用，邮件错误不使用聊天 409。SSE 队列满会结束慢流，重连读取两领域状态及持久 pending；App 同步按序应用事件，每领域恢复任务合并有界，邮件阅读器另一个合并列表任务不阻塞事件消费，后端重启重置 generation。密码写失败只留 App 内存；旧钥匙串删除失败仅持久化账号 id，重建后可精确重试，不存密码。

## 文档

- `kb/docs/module-shell.md` — 双模块的切换、已读、通知与 badge 规则；修改模块外壳或跨模块行为前读。
- `kb/docs/email-foundation.md` — 邮件账号、同步/提醒、独立缓存和正文安全边界；修改邮件服务、存储、解析或展示前读。

## 运行和测试

- CI 与发布：`.github/workflows/ci.yml` 验证测试、独立后端安装和 App 构建；`release.yml` 在推送 `vMAJOR.MINOR.PATCH` 时构建、签名、公证 Universal DMG 并发布到当前仓库。安装依赖和 Secrets 约定见 README「构建和发布」。Release 不内置 Python/larkx，安装命令固定到构建对应的 commit。

- 后端测试：`cd backend && uv run pytest`。App：`cd mac && make test && make build && make run`。
- App 自己拉起后端，不需要单独启动。正式数据在 `~/Library/Application Support/FeishuChat/`，后端日志在 `~/Library/Logs/FeishuChat/backend.log`。
- 聊天接口以 `backend/src/feishu_lite/api.py` 和 `types.py` 为准；邮件接口/共享模型在 `mail/api.py`、`mail/types.py`。App 聊天模型在 `mac/FeishuChatCore/Sources/FeishuChatCore/Models.swift`，邮件模型在同目录 `MailModels.swift`，合成 wire 样本由 Core 测试交叉验证；改已接入接口时两边要一起改。

## 不变量

- larkx 只能以**固定 commit 的 git 依赖**引入，不要拷贝进仓库：上游没有 LICENSE。
- 测试和探路只能往用户指定的测试会话（群 **litetest**）发消息，不要往真实工作群发。
- 本人发的消息不计未读、不弹通知。测试需要"别人发的消息"时，用 litetest 里的自定义机器人：webhook 地址在 `tmp/bot-webhook`（不入库），`tmp/bot_send.sh <文本>` 发送。
- 会在用户屏幕上弹出通知或登录页的测试（比如用凭证副本测"登录已失效"），跑之前先告诉用户：它们和真的一模一样，用户会照着去扫码。
- 在 App 里打开一个会话会把它标成已读，手机上的未读也跟着清掉。用真实账号调试界面时只点测试会话。
- 提交进仓库的协议样本必须脱敏，替换人名、消息内容和各种 id。凭证绝不能进仓库。
