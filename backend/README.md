# feishu-lite-backend

FeishuLite 的本地后端：封装 larkx（逆向飞书网页版协议），在 127.0.0.1 上提供 REST + SSE，SQLite 做本地缓存。平时由 Mac App 拉起，不需要手动运行。

```bash
uv run pytest                                   # 行为测试（FakeSource，不连飞书）
FEISHU_LITE_TOKEN=xxx uv run feishu-lite-backend --port 18765   # 手动启动
uv run feishu-lite-backend login                # 终端里扫码登录（排障用）
```

环境变量：`FEISHU_LITE_TOKEN`（必填，请求头 `Authorization: Bearer <token>`）、`FEISHU_LITE_HOME`（数据目录，默认 `~/Library/Application Support/FeishuChat`）、`FEISHU_LITE_PARENT_PID`（父进程消失时自动退出）。

`src/feishu_lite/mail/` 提供独立 MailService：账号/凭证生命周期、INBOX 同步与历史分页、全箱未读、通知 pending/ack、显式已读和离线正文读取。已接入应用生命周期、全部 `/mail/*` API 和共享 SSE；`/status.features` 包含 `mail`，App 配置/收件箱阅读器已通过自动测试与 Debug 构建，实际 UI/安全隔离尚待独立验收。密码只留内存，重启后等待凭证注入；所有端点沿用 launch token，邮件错误为 `{domain:"mail",code}`，不用聊天 409。存储与事件回调只在事件循环线程使用，IMAP I/O 和解析/净化交专用 daemon；SSE 慢流断开后须重新读两领域状态，邮件 pending 仅由显式 ack 确认。

D2 增加 `GET /mail/messages/{id}/summary`，响应沿用 `MailSummary`（与列表 items 完全相同）。它只读取当前账号/INBOX/UIDVALIDITY 的缓存摘要，不连接 IMAP、不写 Seen；页外通知目标可直接获取元数据，缺失 404、失效身份 410、非 INBOX 400，鉴权同其他邮件端点。App 路由及显示/已读接续见 [D2 报告](../kb/sessions/2026-10-13-email-reader-d2.md)。

完整 wire、错误/等待/取消及进程退出契约见 [C3b 报告](../kb/sessions/2026-10-13-email-api-c3b.md)，服务方法见 [C3a](../kb/sessions/2026-10-13-email-sync-c3a.md)，基础契约见 [C1](../kb/sessions/2026-10-13-email-foundation-c1.md)、[C2](../kb/sessions/2026-10-13-email-imap-executor-c2.md)，当前行为见 [邮件基础文档](../kb/docs/email-foundation.md)。`uv run pytest tests/mail` 使用真实 SQLite、HTTP/SSE、fake IMAP 和脚本化 IMAP/TLS 服务端，不连接真实邮箱。
