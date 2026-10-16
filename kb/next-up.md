# Next up

> 接下来要做的事，按时间排。做完一项就删掉，结果记到条目指定的 kb 文档，这里不留记录。

## 下次干净 macOS 用户环境验收时

- **补齐 Cask 全安装验收**：v0.1.0 已正式发布，签名、公证、tap 更新、Homebrew 下载/校验和、下载后 App Gatekeeper 与隔离后端安装均通过；干净用户环境仍需验证完整 `brew install --cask reorx/tap/feishu-lite`、Finder 启动和下一版本升级。下一版包含 FeishuLite 改名，需验证旧 app 被替换、偏好继承、邮件钥匙串 ACL、通知重新授权及登录项切换；保持 v0.1.0 原产物不变。
  → 操作见 `kb/docs/releases.md`，结果记到 `kb/sessions/2026-10-16-homebrew-release.md`。

## 邮箱阶段 F 真实验收前，用户指定测试邮件与发件来源后

- **补齐邮箱真实验证**：验证 SELECT/STORE 的 `\Seen` 持久化与官方端可见、跨端 FLAGS/60 秒未读对账、新信推送及通知；长期 IDLE 断开周期另行观察。A 只读接入与库选型已通过，但这些项目未测，不用工作邮件代替测试样本，不制造错误密码或连接数压力。
  → 条件与已有证据见 `kb/notes/2026-10-13-email-imap-probe.md`，结果由对应执行者写入阶段 session。

## F1b 报告签收后，协调者安排少量 F1 接续时

- **补精确未验边界**：未知能力稳定加载UI；旧didFinish/新navigation乱序与已发STORE期间账号/UIDVALIDITY变化；HTTPS/单标签内网外开及跨邮件/token动态探测。用最新源码、假Keychain、可控合成服务及presentation/navigation/请求时间关联，不用总read数判缺陷。HTML滚动P2、新scheme隔离、浅色/拖宽/cursor恢复/fake凭证错误UI已验证；R2纯文本滚动P2已由F1c关闭，真实中文组字/精确旧layout等准确边界见 [F1c报告](sessions/2026-10-14-email-reader-f1c-acceptance.md)，不重复全部F1矩阵。
  → [F1b报告](sessions/2026-10-14-email-reader-f1b-acceptance.md)列出最小接续与准确边界，证据在 `tmp/2026-10-14-email-reader/f1b-acceptance/`；仍遵守context/桌面约定，不自行启动F2。

## F2c 报告签收后，协调者安排最小接续时

- **有限 GUI 余项**：F2c已完成稳定合成连接下取消隐藏/扫码状态、邮箱auth_failed/HTTP timeout期间聊天历史、实际键入后点击发送与草稿；只接续可用键盘设置下R3 Tab/Return、中文 IME 及聊天 Return 有效事件证据，不以按钮发送代替。运行中通知权限切换、410/旧账号点击、旧聊天payload和系统add部分失败按F2a边界少量接续，不重跑整个矩阵。R3布局P2、生产Supervisor生命周期、合成唤醒及全量已验；机器真实睡眠另行安排。
  → [F2c报告](sessions/2026-10-14-email-keychain-chat-f2c.md)保留新 service 真实隔离、限定聊天和首败/清理；[F2b报告](sessions/2026-10-14-email-system-integration-f2b.md)保留旧矩阵和授权阻塞；[F2a报告](sessions/2026-10-14-email-system-notifications-f2a.md)保留系统精确未验。继续保护正式App/权限/数据。
