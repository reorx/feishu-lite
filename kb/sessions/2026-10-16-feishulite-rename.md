---
created: 2026-10-16
tags: [macos, rename, migration, release]
---
# 原生客户端统一改名为 FeishuLite

## 概要

在当前 master 上将 FeishuChat 原生客户端改名为 FeishuLite，bundle ID 改为 `com.reorx.FeishuLite`。工程、target、Swift package/module、源文件目录、菜单/窗口/通知名称、日志、DMG、Release 工作流与 Cask 生成器同步更新。源码和手动工作流默认版本推进到 0.1.1，未发布或推送 tag；已发布 v0.1.0 和线上 tap 保持原样。

检查 `/Applications/Feishu Lite.app/Contents/Info.plist` 确认旧应用的 bundle ID 为 `com.reorx.feishu-lite`，可执行文件为 `pake-feishulite`。通过 FileManager 的 trashItem 移到 `~/.Trash/Feishu Lite.app`，没有删除原生 App、数据或钥匙串。

## 修改的文件

- `mac/project.yml`、`Makefile`、两个 `Package.swift` 及整个源代码/测试目录：统一 FeishuLite/FeishuLiteCore/FeishuLiteState 命名，由 XcodeGen 重建工程和 plist。
- `mac/FeishuLite/Services/IdentityMigration.swift` 和 AppDelegate：在模型创建前一次性导入旧 UserDefaults 中缺失的值，不覆盖新值、不删除旧域。
- `MailKeychain.swift`、后端 `main.py`：注明兼容存储标识，仍使用旧数据目录和邮件 service，保留精确 UUID 与 Debug/Release 隔离。
- `.github/workflows/release.yml`、DMG/图标/Release notes/Cask 脚本：新产物名；Cask 生成器在输入 0.1.0 时仍返回旧名称。
- README、两级 AGENTS、当前发布/模块文档、next-up：说明新旧身份、升级操作和待发布验证；历史计划和 session 保留原事实。`kb/todo.md` 的用户改动未修改、未纳入提交。

## 验证

- 先新增 UserDefaults 行为测试并观察缺少 IdentityMigration 的编译失败；再实现一次迁移、新值优先、已删值不复活、干净安装不再导入后来的旧状态。
- 新增 v0.1.0 Cask 历史产物测试，先观察失败再实现版本分支。
- `make -C mac test`：Core 74、App 98 项全部通过；MailKeychain 现有隔离测试继续通过。
- `cd backend && uv run pytest`：311 项通过。
- Cask 4 项行为测试通过，包括 Ruby recorder 实际执行安装/升级钩子；`actionlint`、shell 语法和 `git diff --check` 通过。
- Debug 构建通过。常规 Release 构建因本机未配置签名 Team 失败；使用 `make build-release RELEASE_XCARGS=CODE_SIGNING_ALLOWED=NO` 验证 Universal 编译通过，lipo 确认为 x86_64 + arm64，构建 plist 的 bundle ID 为 `com.reorx.FeishuLite`。没有改动 Release 的 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`。
- `make dmg` 成功产生改名后的 DMG；它是未签名的本地测试产物，不是正式发布包。
- 实机前 context 检查为 20%，按用户要求未开其他 agent/tab。读取桌面验收约定并执行 wake-screen。以外部不可用本机 endpoint 启动 Debug App，不启动真实后端，不碰真实会话/邮箱；屏幕确认菜单栏、窗口标题、系统通知授权提示均为 FeishuLite。窗口因隔离 endpoint 不可用停在启动页，不能视为聊天回归验收。
- 首张全屏截图全黑，重新 wake-screen 后获得有效截图。System Events AX 检查被辅助功能权限拒绝，未绕过权限；通过屏幕和 CGWindowList 完成命名检查。截图、脚本、测试日志在 `tmp/2026-10-16-rename/`，单窗口证据为 `feishulite-window.png`。
- 使用 NSRunningApplication 结束此次新 App，确认无残留 FeishuLite 进程；`mac-dev-cleanup --only browser --min-age 2` 返回 nothing to clean，未启动模拟器或浏览器。

## 注意事项

数据目录保留 `Application Support/FeishuChat`，避免复制/改名活动 SQLite 或遗失凭证，也保持旧版本回退的路径一致。邮件 Keychain service 是稳定存储标识，保留它不等于保留旧 bundle ID；新签名访问旧 ACL 仍可能需要授权，已有拒绝/锁定/重新输入流程保持有效。

UserDefaults 迁移包含通知 receipt/intent 和待删除凭证 UUID，防止改名直接丢失去重及清理状态。旧通知属于旧 bundle，新 App 无法查询、清除或接管其点击。登录项也不能由新 bundle 的 mainApp 注销旧项：升级前在旧 App 关闭开机启动，再在新 App 开启；旧 App 不可用时从系统设置移除旧项。

本机 Homebrew `cask/upgrade.rb` 的升级链路先通过旧 Cask start_upgrade 移走旧 artifact，再安装新 artifact；保持同一 token 即可处理 app 文件名变化，不添加可能误删手动安装 App 的全局删除钩子。

## 遗留问题

下一版发布时需验证新身份的 Developer ID 签名、公证、Gatekeeper，以及干净用户从 v0.1.0 的完整 Cask 升级、真实历史钥匙串 ACL、通知和登录项切换。此次未动线上 tap 或发布资源；这些检查已接入 `kb/next-up.md`。真实聊天/邮箱业务回归沿用既有测试和已知问题，不宣称此次重新验收。

## 相关文档

- [发布指南](../docs/releases.md) — 更新完整改名升级说明。
- [首次正式发布记录](2026-10-16-homebrew-release.md) — 保持 v0.1.0 和线上 tap 的历史事实。
- [MVP 计划](../plans/2026-09-29-feishu-chat-mvp-plan.md) — 原先避让旧 Pake 名称的历史依据。
