# Next up

> 接下来要做的事，按时间排。做完一项就删掉，结果记到条目指定的 kb 文档，这里不留记录。

## Apple 开发者账号持有人接受待处理协议后

- **完成首次发布**：运行 `gh workflow run release.yml --ref master`，确认 Apple 公证、staple 与 artifact 上传成功，再推送 `v0.1.0` 标签并检查当前仓库 Release 的 DMG 和依赖安装说明。首次运行已完成签名和打包，但公证返回协议缺失 HTTP 403。
  → 结果记到 `kb/sessions/2026-10-08-release-ci.md`。

## 邮箱阶段 F 真实验收前，用户指定测试邮件与发件来源后

- **补齐邮箱真实验证**：验证 SELECT/STORE 的 `\Seen` 持久化与官方端可见、跨端 FLAGS/60 秒未读对账、新信推送及通知；长期 IDLE 断开周期另行观察。A 只读接入与库选型已通过，但这些项目未测，不用工作邮件代替测试样本，不制造错误密码或连接数压力。
  → 条件与已有证据见 `kb/notes/2026-10-13-email-imap-probe.md`，结果由对应执行者写入阶段 session。

## F1b 报告签收后，协调者安排少量 F1 接续时

- **独立复验纯文本R2**：自动返修已完成；用最新源码、fake Keychain和合成后端重建独立副本，复验159滚动→Messages→Email、159→158→159和快速切换的首可见文字位置，核对GET/read/资源计数。另验原生TextKit的800×460/鼠标拖宽换行、深浅色、空/长正文、选择/复制、输入及回车不改正文/不发聊天、字面HTML和自动资源零请求。不沿用旧二进制或自动结果签收屏幕；步骤见 [R2报告](sessions/2026-10-14-email-plain-scroll-r2.md)，结果另写独立session。
- **补精确未验边界**：未知能力稳定加载UI；旧didFinish/新navigation乱序与已发STORE期间账号/UIDVALIDITY变化；HTTPS/单标签内网外开及跨邮件/token动态探测。用最新源码、假Keychain、可控合成服务及presentation/navigation/请求时间关联，不用总read数判缺陷。HTML滚动P2、新scheme隔离、浅色/拖宽/cursor恢复/fake凭证错误UI已验证，不重复全部F1矩阵。
  → [F1b报告](sessions/2026-10-14-email-reader-f1b-acceptance.md)列出最小接续与准确边界，证据在 `tmp/2026-10-14-email-reader/f1b-acceptance/`；仍遵守context/桌面约定，不自行启动F2。

## 邮箱 E 自动实现签收后，协调者另派 F2 时

- **补通知/点击/唤醒实测**：用 E 合成 HTTP 入口独立验证逐封/汇总、部分失败与 ack 重试、跨模块/页外/失效点击、读删清理、未知投递“再次提醒”及最小窗口提示、实际睡眠恢复和退出清理。需可用隔离通知权限；自动 recorders 不代表系统 banner 或点击通过，不读取真实邮箱凭证或改变正式 App 权限。
  → 崩溃窗口、测试证据、入口和逐项清单见 `kb/sessions/2026-10-14-email-notifications-e.md`；F1 未执行这些系统集成项，留 F2。
