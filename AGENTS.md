# AGENTS.md

FeishuChat：不依赖飞书官方客户端的轻量飞书聊天客户端（macOS）。协议层走**逆向网页版协议**（cv-cat/LarkAgentX 的 `larkx` 包），不走官方 OpenAPI，因为公司租户是免费版，API 额度撑不起单聊的实时通知。选型依据见 `kb/notes/2026-09-29-feishu-chat-access-research.md`。

## 结构

- `backend/`：Python（uv）后端 `feishu-lite-backend`，封装 larkx，对外提供 127.0.0.1 上的 REST + SSE 接口，本地缓存用 SQLite。
- `mac/`：SwiftUI App `FeishuChat`（bundle id `com.reorx.FeishuChat`），负责拉起并守护后端子进程、界面和通知。工程约定和 App 的工作方式见 `mac/AGENTS.md`，改 App 之前先读。
- `kb/`：计划、笔记、session 总结；`kb/known-issues.md` 是已知问题的唯一清单，`kb/next-up.md` 是到期要做的检查。
- `tmp/`：探路脚本、验收脚本和截图，已 gitignore。

## 当前状态

MVP 功能已经做完：扫码登录、会话列表、历史消息和翻页、发文本、实时消息、本地通知、Dock 角标、开机启动。计划和验收清单在 `kb/plans/2026-09-29-feishu-chat-mvp-plan.md`，验收结果在 `kb/sessions/`。

## 运行和测试

- 后端测试：`cd backend && uv run pytest`。App：`cd mac && make test && make build && make run`。
- App 自己拉起后端，不需要单独启动。正式数据在 `~/Library/Application Support/FeishuChat/`，后端日志在 `~/Library/Logs/FeishuChat/backend.log`。
- 接口约定以 `backend/src/feishu_lite/api.py` 和 `types.py` 为准；App 这边对应的模型在 `mac/FeishuChatCore/Sources/FeishuChatCore/Models.swift`，两边要一起改。

## 不变量

- larkx 只能以**固定 commit 的 git 依赖**引入，不要拷贝进仓库：上游没有 LICENSE。
- 测试和探路只能往用户指定的测试会话（群 **litetest**）发消息，不要往真实工作群发。
- 在 App 里打开一个会话会把它标成已读，手机上的未读也跟着清掉。用真实账号调试界面时只点测试会话。
- 提交进仓库的协议样本必须脱敏，替换人名、消息内容和各种 id。凭证绝不能进仓库。
