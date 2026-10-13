# Next up

> 接下来要做的事，按时间排。做完一项就删掉，结果记到条目指定的 kb 文档，这里不留记录。

## Apple 开发者账号持有人接受待处理协议后

- **完成首次发布**：运行 `gh workflow run release.yml --ref master`，确认 Apple 公证、staple 与 artifact 上传成功，再推送 `v0.1.0` 标签并检查当前仓库 Release 的 DMG 和依赖安装说明。首次运行已完成签名和打包，但公证返回协议缺失 HTTP 403。
  → 结果记到 `kb/sessions/2026-10-08-release-ci.md`。

## 邮箱阶段 F 真实验收前，用户指定测试邮件与发件来源后

- **补齐邮箱真实验证**：验证 SELECT/STORE 的 `\Seen` 持久化与官方端可见、跨端 FLAGS/60 秒未读对账、新信推送及通知；长期 IDLE 断开周期另行观察。A 只读接入与库选型已通过，但这些项目未测，不用工作邮件代替测试样本，不制造错误密码或连接数压力。
  → 条件与已有证据见 `kb/notes/2026-10-13-email-imap-probe.md`，结果由对应执行者写入阶段 session。

## 2026-10-14 F1 交付后，协调者派返修与独立接续时

- **返修并复验 HTML 阅读位置**：切 Messages 再回 Email 丢失 HTML 滚动位置（P2）。修复后用最新产品源码重建隔离副本，复验滚动、首载规则门、资源隔离与可见性已读。
- **补齐 F1 未验项**：浅色、实际鼠标拖宽、旧 cursor 完整恢复、未知能力/fake Keychain 失败 UI、账号/UIDVALIDITY/连接变化的渲染归因；旧连接用例81不可凭总read数判缺陷或通过。只用合成数据。
  → 完整矩阵、复现步骤和工具定位纠正在 `kb/sessions/2026-10-14-email-reader-f1-acceptance.md`，证据在 `tmp/2026-10-14-email-reader/f1-acceptance/`。本次资源已清理，接续 tab 仍遵守 context/桌面测试约定。

## 邮箱 E 自动实现签收后，协调者另派 F2 时

- **补通知/点击/唤醒实测**：用 E 合成 HTTP 入口独立验证逐封/汇总、部分失败与 ack 重试、跨模块/页外/失效点击、读删清理、未知投递“再次提醒”及最小窗口提示、实际睡眠恢复和退出清理。需可用隔离通知权限；自动 recorders 不代表系统 banner 或点击通过，不读取真实邮箱凭证或改变正式 App 权限。
  → 崩溃窗口、测试证据、入口和逐项清单见 `kb/sessions/2026-10-14-email-notifications-e.md`；F1 未执行这些系统集成项，留 F2。
