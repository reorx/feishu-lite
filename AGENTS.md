# AGENTS.md

FeishuChat：不依赖飞书官方客户端的轻量飞书聊天客户端（macOS）。协议层走**逆向网页版协议**（cv-cat/LarkAgentX 的 `larkx` 包），不走官方 OpenAPI，因为公司租户是免费版，API 额度撑不起单聊的实时通知。选型依据见 `kb/notes/2026-09-29-feishu-chat-access-research.md`。

## 结构

- `backend/`：Python（uv）后端 `feishu-lite-backend`，封装 larkx，对外提供 127.0.0.1 上的 REST + SSE 接口，本地缓存用 SQLite。
- `mac/`：SwiftUI App `FeishuChat`（bundle id `com.reorx.FeishuChat`），负责拉起并守护后端子进程、界面和通知。
- `tmp/`：探路脚本和截图，已 gitignore。

## 当前状态

还在开发。按计划执行：`kb/plans/2026-09-29-feishu-chat-mvp-plan.md`。

## 不变量

- larkx 只能以**固定 commit 的 git 依赖**引入，不要拷贝进仓库：上游没有 LICENSE。
- 测试和探路只能往用户指定的测试会话发消息，不要往真实工作群发。
- 提交进仓库的协议样本必须脱敏，替换人名、消息内容和各种 id。凭证绝不能进仓库。
