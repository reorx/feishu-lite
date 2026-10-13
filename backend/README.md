# feishu-lite-backend

FeishuChat 的本地后端：封装 larkx（逆向飞书网页版协议），在 127.0.0.1 上提供 REST + SSE，SQLite 做本地缓存。平时由 Mac App 拉起，不需要手动运行。

```bash
uv run pytest                                   # 行为测试（FakeSource，不连飞书）
FEISHU_LITE_TOKEN=xxx uv run feishu-lite-backend --port 18765   # 手动启动
uv run feishu-lite-backend login                # 终端里扫码登录（排障用）
```

环境变量：`FEISHU_LITE_TOKEN`（必填，请求头 `Authorization: Bearer <token>`）、`FEISHU_LITE_HOME`（数据目录，默认 `~/Library/Application Support/FeishuChat`）、`FEISHU_LITE_PARENT_PID`（父进程消失时自动退出）。

`src/feishu_lite/mail/` 提供邮件模型、独立 mail.db、MIME/正文净化，以及真实 IMAPClient 的 INBOX 适配器与专用 daemon 执行器；尚未接入同步调度、应用生命周期或邮件 API。存储只能在所属事件循环线程使用，IMAP I/O 和解析/净化交工作线程；数据契约见 [C1 报告](../kb/sessions/2026-10-13-email-foundation-c1.md)，异步接口、世代/取消和关停限制见 [C2 报告](../kb/sessions/2026-10-13-email-imap-executor-c2.md)，行为说明见 [邮件缓存与安全正文](../kb/docs/email-foundation.md)。`uv run pytest tests/mail` 使用合成数据和本地脚本化 IMAP/TLS 服务端，不连接真实邮箱。
