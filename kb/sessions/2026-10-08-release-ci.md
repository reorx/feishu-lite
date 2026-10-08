---
created: 2026-10-08
tags:
  - ci
  - release
  - macos
---

# 接入 GitHub 构建发布与后端安装引导

## 概要

参考 vocalflow-mac 的发布流程，新增当前仓库的 CI 和 Release 工作流。发布版改为运行用户安装的 Python 后端，去掉开发机源码路径依赖；缺少后端时显示安装命令并支持重新检测。DMG 支持 arm64/x86_64，正式产物必须经过 Developer ID 签名和 Apple 公证。

## 修改的文件

- `.github/workflows/`：普通 CI 验证前后端测试、独立工具安装和构建；Release 负责签名、公证及当前仓库发布，手动运行只上传 artifact。
- `mac/Makefile`、`mac/scripts/make-dmg.sh`、`mac/project.yml`、`mac/Config/Release.xcconfig`：Universal 构建、DMG、版本号和后端源 commit。
- `BackendInstallation` 及行为测试：检查 uv 默认目录、Homebrew、自定义工具目录和 PATH，支持安装后的重新检测。
- `BackendConfig`、`BackendSupervisor`、`AppState`、`RootView`：发布版调用独立工具，缺失时暂停重试并显示安装引导。
- `backend/pyproject.toml`：将 larkx 固定 Git commit 写入标准依赖元数据，保证安装 wheel 时仍使用正确来源。
- `README.md`、`scripts/release-notes.sh`、两级 `AGENTS.md`：安装前提、构建发布约定及 Release 文案。

## 验证

- 行为测试先失败后实现；55 项 Swift 测试、39 项 Python 测试通过。
- Debug、Universal Release 构建通过；`lipo` 确认 arm64 和 x86_64；DMG 打包通过。
- wheel 在独立 uv tool 目录安装成功，包含固定 commit 的 larkx；隔离 App 使用该工具启动成功。
- 从 GitHub 的 `c072ffa` commit 执行完整 `uv tool install` 命令也通过，确认远端 Git 安装链路可用。
- 独立 bundle ID 和数据目录验收：缺少依赖显示引导，安装后按「已安装，重新检测」进入登录页，未扫码、未访问真实账号。
- 截图与 AX 证据：`tmp/2026-10-08-release-ci/`。测试 App 已退出。
- [GitHub CI 37765084270](https://github.com/reorx/feishu-lite/actions/runs/37765084270) 全部通过：Linux 后端测试和独立安装、macOS Swift 测试、Debug 与 Universal Release 构建。
- [GitHub Release 37765079451](https://github.com/reorx/feishu-lite/actions/runs/37765079451) 测试、证书导入、Universal 构建、Developer ID 签名验证和 DMG 打包通过；Apple 公证因账号协议阻塞（见下）。

## 注意事项

- `tool.uv.sources` 是开发时的来源配置，不能替代 wheel 的标准依赖元数据；固定 Git 来源必须写入 `project.dependencies`。参考 https://docs.astral.sh/uv/concepts/projects/dependencies/ 。
- Release 安装命令固定到构建的 Git SHA，升级 App 时也需要执行对应后端安装命令。
- 六个仓库 Secrets 从统一 Apple 凭据目录经 envops 安全传入；不需要跨仓库发布 Token，未复制凭据进仓库。
- 不内置 larkx 源码，继续以固定 commit 的 Git 依赖安装。

## 遗留问题

- Apple notarytool 返回 HTTP 403：`A required agreement is missing or has expired`。账号持有人需在 Apple Developer / App Store Connect 接受待处理协议，再手动运行 Release 工作流验证公证。不能通过代码解决，也不退回未公证发布。
- 尚未创建 `v0.1.0` 标签或正式 Release；公证成功后创建标签即可触发当前仓库发布。跟进条件记在 `kb/next-up.md`。
