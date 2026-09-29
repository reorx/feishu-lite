# Next up

> 接下来要做的事，按时间排。做完一项就删掉，结果记到条目指定的 kb 文档，这里不留记录。

## 2026-09-30 22:30 CST 之后

- **登录 24 小时后仍在线**（验收第 9 项）：正式凭证是 2026-09-29 22:27 扫码拿到的，App 从 22:33 起不经代理运行。检查 `pgrep -lx FeishuChat` 有进程；App 侧栏顶部显示"在线"；`grep -c 'keepalive ok' ~/Library/Logs/FeishuChat/backend.log` 大约每 4 小时加 1；`grep -n 'logged out' ~/Library/Logs/FeishuChat/backend.log` 在 22:27 之后没有新记录。再往测试群 litetest 发一条消息，确认 App 里几秒内出现。
  中途如果 App 被重启过（做剩下的验收时会重启），不影响这项检查：要验证的是扫码拿到的凭证能不能撑过 24 小时。
  → 通过：删掉 `kb/known-issues.md` 里「保活：扫码会话的有效期和续期方式没有验证」一条，结果记到当次 session 总结。没通过：把掉线时间和 `backend.log` 里的报错补进那一条。
