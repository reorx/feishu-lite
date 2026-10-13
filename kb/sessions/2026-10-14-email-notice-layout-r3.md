---
created: 2026-10-14
tags:
  - email
  - layout
  - repair
---

# R3：未知投递恢复提示独立占位

## 概要

按协调计划当前 R3 执行，基线 `ccb2595`（F2a报告 `7c12278`）。完整阅读协调计划，查看 F2a 的18/18b截图与AX；先用生产 EmailWorkspace 的无窗口宿主复现失败，再最小修复布局。未改后端、通知协调器、receipt/ack/重试接口或文案含义；本tab没有GUI验收、委派或开展F2b。

根因：外层 `safeAreaInset` 没有让 NavigationSplitView 的原生 sidebar 实际下移。改为普通 VStack 中提示与 split view 两行，提示按内容占高、文字允许纵向换行、按钮保持完整尺寸；无提示不占空间。没有固定窗口尺寸或偏移补丁。

## 验证

证据目录：`tmp/2026-10-14-email-reader/r3-notice-layout/`。

- `red.log`：修改布局前，split顶部0、收件箱菜单顶部20；独立占位两条几何断言失败。测量实际 NSSplitView/NSPopUpButton，不镜像VStack实现。
- `green-expanded.log`：最小/正常工作区723×460、903×628（扣除左导航和标题栏），1/2048条未知记录；收件箱、选中正文、配置和模块式拆除重建共16组通过。提示占高58，菜单顶部78，最小剩余内容402；无提示时split完整460高度、菜单位置重建一致。
- `make-test-recheck.log`：Core74、App92项全部通过；含新增2个测试（参数化4例）、放大文字后提示自然增高到75点、不额外取正文/列表或read/ack/投递的断言。
- `make-build.log`：`cd mac && make build` Debug成功。仅改布局，不重复后端检查，不运行formatter/linter。
- 首次 `make-test.log` 的既有 SSE 用例 `productionStreamConsumerMaintainsChatOrderDuringHeldMailStatusAndEndsCleanly` 出现一次 `/mail/status <= 2` 断言失败，原因未定位；`stream-recheck.log` 单独复跑及上述全量复跑通过。保留首败，不修改范围外逻辑。

无窗口几何不证明实际标题栏/屏幕文字、鼠标和键盘操作通过。F2a失败截图继续归档于 `tmp/2026-10-14-email-reader/f2a-acceptance/18-unknown-intent-minimum.png`、`18b-unknown-normal.png`；本次没有新GUI截图。

## 修改的文件

- `mac/FeishuChat/UI/EmailWorkspace.swift`：仅提示容器与文字/按钮尺寸约束；两种重试按钮调用、优先级和禁用条件保持。
- `mac/Package.swift`、`mac/Tests/FeishuChatStateTests/MailNoticeLayoutTests.swift`：直接编译生产邮件视图，用假网络/通知和独立偏好做无窗口几何回归。
- 根/mac AGENTS、原计划、known-issues/next-up、module-shell文档：更新自动修复与独立复验状态，不勾选F/F2、不修改协调计划。

## 注意事项

自主选择原生普通布局占位；保持既有split view、列宽、阅读器和配置分支，不注入生产测量探针。假偏好、宿主及任务在测试defer中释放，测试进程已退出；未启动App/后端监听/浏览器/模拟器/caffeinate，也未接触真实数据或钥匙串。`cleanup-check.log`、`mac-dev-cleanup.log` 均确认浏览器资源无可清理项，未影响用户进程。

## 遗留问题与交给协调者

P2保留为“修复待独立复验”。下一独立tab从最新源码重建正常隔离副本，沿用F2a的 `unknown_check.py` / `recheck_unknown.py` 播种方式：

1. 复验内容800×460及窗口980×680：提示/工具栏分别占位，说明完整可读，列表与详情可用；补较长计数/换行。
2. 切Messages再Email、开配置/返回、选正文；清除提示后布局恢复。
3. 鼠标及Tab/Return操作“再次提醒”，关联fixture和真实center计数，确认保留F2a的显式投递/ack语义。

本tab停在R3；实机签收与后续任务由协调者安排。

## 相关文档

- [协调计划](../plans/2026-10-13-email-reader-coordination.md) — 完整阅读，执行R3，未修改。
- [原计划](../plans/2026-10-13-email-reader-plan.md) — 通知恢复要求及状态更新。
- [F2a报告](2026-10-14-email-system-notifications-f2a.md) — 两轮失败截图、AX和播种入口。
- [模块外壳](../docs/module-shell.md) — 补恢复提示的展示规则。
- [邮件基础](../docs/email-foundation.md) — 参考通知恢复和正文安全边界，未变更。
