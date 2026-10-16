---
created: 2026-10-16
tags: [release, homebrew, github-actions]
---
# 补齐 FeishuChat 的签名 DMG 与 Homebrew 发布链路

## 概要

对照同层 vocalflow-mac 的 Developer ID / notarytool 工作流及 mdnotate 的 Cask 更新方式，扩展本仓库已有 Release 流程。产物仍发布在 reorx/feishu-lite；独立 Homebrew job 下载已发布 DMG 并验证校验和，生成和推送 reorx/homebrew-tap/Casks/feishu-lite.rb。Cask 安装与升级时通过 uv 安装与 App 相同 commit 的后端，目标命令为 `brew install --cask reorx/tap/feishu-lite`。

## 修改的文件

- `.github/workflows/release.yml`：增加双架构检查、DMG 签名与 Gatekeeper 验证、独立 tap 发布 job；支持仅重试失败 Cask job、首次创建、幂等更新与禁止降级。手动 dispatch tag 也不发布。
- `.github/workflows/ci.yml`、`scripts/tests/`：先写行为测试并观察因生成器缺失失败，再实现；覆盖校验和/版本/后端 commit、无效参数、安装/升级执行、失败传播和 Finder 可发现的后端路径。
- `scripts/render-cask.sh`：生成具有 uv/Git 依赖、macOS 14 下限和 pinned backend 安装钩子的 Cask。
- `scripts/release-notes.sh`、`README.md`、`kb/docs/releases.md`、`AGENTS.md`：说明 Cask / DMG 两种安装方式、凭据、发布及故障恢复。
- `kb/next-up.md`、`kb/known-issues.md`：修正过时的“没有 Release 流程”，准确记录尚未通过线上验收的状态。

## 验证

- `uv run --no-project python -m unittest discover -s scripts/tests -v`：3 项通过（含无效输入子用例）；Ruby recorder 实际执行生成 Cask 的安装钩子两次，未调用真实 uv 或触碰用户后端。
- `actionlint`：通过，包含工作流嵌入 shell 的检查。
- `bash -n`：生成器、Release notes 和 DMG 脚本通过。
- 临时本地 tap 中 `brew info --cask --json=v2` 成功解析生成 Cask；未安装 App，未修改真实 tap。临时 tap 已删除。
- Homebrew 官方文档核对了第三方 Ruby postflight 兼容性；本机对其发出弃用提示，详细迁移边界已在发布指南记录。
- 未运行 UI 验收、未发消息、未创建浏览器/模拟器，无截图和此类测试资源需清理。

## 注意事项

TAP_PUSH_TOKEN 缺失时明确使 Homebrew job 失败，不像参考项目那样静默跳过。凭据由 checkout action 管理，不写入 clone URL。SHA256 来自完成 staple 后的最终文件。普通卸载保留 uv 后端和用户数据。原有 `kb/todo.md` 工作区修改未纳入本次提交。

## 遗留问题

六项签名 Secrets 已配置，但 TAP_PUSH_TOKEN 缺失。历史运行 37765079451 在公证时返回 Apple 开发者协议缺失/过期 HTTP 403，此次没有重新进行线上公证，因此当前协议状态未知。仓库尚无正式 Release；须按发布指南补齐凭据、试运行，再发布首个 tag 并验证真实安装/升级。本次仅完成本地实现和验证，未推送代码或发布标签。

## 相关文档

- [发布指南](../docs/releases.md) — 本次新增。
- [原发布流程记录](2026-10-08-release-ci.md) — 本次接续已有签名、公证流程。

## 继续配置与线上验证

用户要求自行查找并配置已有凭据。已阅读 VocalFlow Mac 的签名文档和 `~/Sync/apple-developer/AGENTS.md`，使用 envops 读取权威来源，同步六项签名 Secrets。TAP_PUSH_TOKEN 使用现有 gh OAuth token 通过 stdin 配置，已验证 tap 写权限；该 token 权限范围为账号级 repo，并非仅限 tap 的 PAT。所有凭据均未输出或提交。

notarytool history 已成功，历史协议 403 未重现。隔离 uv tool 目录实际从 GitHub 安装 eb947b5 后端并执行 --help 成功。代码已推送；手动运行 38864857590 暴露 Release 从仓库根目录跑 pytest 导致子进程无法 import tests.mail（17 failed / 294 passed），将执行目录改为 backend，与普通 CI 一致。

修正 pytest 工作目录后本地全量 311 passed。运行 38865281453 已通过全部测试和 Developer ID Universal 构建，但新增 lipo -verify_arch 的参数被工具误解析；改为 lipo -archs 并检查两个架构，已在本机现有 Universal App 验证。继续试运行。
