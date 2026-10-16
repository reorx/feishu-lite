---
created: 2026-10-16
tags: [release, homebrew, macos]
---
# 发布 FeishuChat

用户通过 `brew install --cask reorx/tap/feishu-lite` 安装。Cask 安装 FeishuChat.app，同时安装 uv、Git 及与 App 对应 commit 的 Python 后端。首次正式 Release 和 Cask 成功发布后，这条命令才可用。DMG 用户按照 Release 页说明手动安装后端。

## 发布流程

推送 `vMAJOR.MINOR.PATCH` 标签触发 `.github/workflows/release.yml`：

1. 运行 Swift、Python 和 Cask 行为测试，验证独立 wheel 安装。
2. 导入临时钥匙串中的 Developer ID Application 证书，构建 arm64 + x86_64 Universal App，开启 hardened runtime 和签名时间戳。
3. 签名 App 与 DMG，将 DMG 提交 Apple 公证；staple、验证票据和 Gatekeeper 后才计算 SHA256。
4. 上传 artifact，并将 DMG、SHA256SUMS 发布到当前仓库 GitHub Release。
5. 独立 Homebrew job 下载已发布的 DMG，核验 SHA256SUMS，生成 `Casks/feishu-lite.rb`，提交并推送到 `reorx/homebrew-tap`。

手动 `workflow_dispatch` 仅生成 artifact，包括手动选择 tag 的情况。正式发布必须 push tag。安装钩子将后端固定到构建 commit，不跟随 master。重试旧版本不能降低 tap 中的版本。

## 首次配置

在 `reorx/feishu-lite` 的 Actions Secrets 配置：

| Secret | 内容 |
|---|---|
| `CERT_P12` | Developer ID Application 证书及私钥的 p12，base64 |
| `CERT_P12_PASSWORD` | p12 导出密码 |
| `APPLE_TEAM_ID` | 开发者 Team ID |
| `ASC_PRIVATE_KEY` | App Store Connect API 私钥 p8，base64 |
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | API Issuer ID |
| `TAP_PUSH_TOKEN` | fine-grained PAT，仅授权 reorx/homebrew-tap 的 Contents 读写 |

本仓库 `GITHUB_TOKEN` 只能发布当前仓库，无法更新 tap。Token 可在 GitHub 设置页录入，或运行 `gh secret set TAP_PUSH_TOKEN --repo reorx/feishu-lite` 后交互输入，不要粘贴进命令或提交文件。

Apple 签名凭据的权威来源是 `~/Sync/apple-developer/`，先读该目录的 `AGENTS.md`，通过 envops 获取 `secrets.env`，文件类 Secret 直接 base64 编码后送给 `gh secret set`；不要输出或在仓库保存密钥。不能从其他 GitHub 仓库下载 Secret 明文。

2026-10-16 已从该目录同步六项签名 Secrets，并用本机 `gh auth token` 经 stdin 配置 TAP_PUSH_TOKEN，确认有 tap 写权限。当前复用的是 GitHub CLI OAuth token，拥有 `repo` 等账号级权限，并非仅限 tap 的 fine-grained PAT；以后更换凭据可使用上表的最小权限 PAT。Apple notarytool history 当前成功，历史协议 403 未重现。没有成功公证的包不会上传或发布。

## 验证与正式发布

先提交并推送当前分支。默认分支上的试运行：

```sh
gh workflow run release.yml --ref master
gh run list --workflow release.yml
```

确认测试、签名、公证、Gatekeeper 与 artifact 上传均成功后，首次发布：

```sh
git tag v0.1.0
git push origin v0.1.0
```

等待 Release 和 Homebrew 两个 job 均成功，在干净用户环境验证安装、Finder 启动、后端就绪和升级。不要用正式聊天会话做点击验收。

如果仅 Homebrew job 失败，修复 Token 或 tap 冲突后使用 GitHub 的 Re-run failed jobs。它下载已发布 DMG，无需重做签名和公证。已存在同版本 Cask 且内容一致时不会提交；tap 有更新版本时会拒绝降级。Release 同版本重试会替换产物，因此尽量只重试失败 job，正式修复优先发新版本。

## 安装和卸载边界

安装与升级需要访问 GitHub、Python 下载源和包源。uv 安装失败会使 Cask 安装报错，网络恢复后可 `brew reinstall --cask reorx/tap/feishu-lite` 重试。升级前退出 FeishuChat，避免正在运行的后端与磁盘版本不一致。

后端入口固定安装到当前用户 `~/.local/bin`，Finder 启动可发现；Cask 为当前用户安装后端，不为其他 macOS 用户预装。普通卸载保留登录、消息、邮箱和 uv 后端，不添加会清空数据的 zap。需要单独卸载后端时执行 `uv tool uninstall feishu-lite-backend`。

Cask 使用第三方 tap 仍兼容的 Ruby `postflight`，用于调用需要联网和用户目录写入的 uv 安装。当前 Homebrew 会提示该钩子弃用；后续迁移到结构化 `postflight_steps` 时需声明网络权限和 uv 的写目录，并实际复验沙箱中的 Python/Git 下载，不能只替换 DSL 名称。官方规则见 [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-flight_steps)。

## 实现与检查

- `.github/workflows/release.yml`：构建、签名、公证、发布、tap 更新。
- `scripts/render-cask.sh`：版本 / SHA256 / commit 校验及 Cask 生成。
- `scripts/tests/`：元数据与安装/升级钩子的隔离行为验证。
- `scripts/release-notes.sh`：Cask 和 DMG 安装说明。
- `mac/scripts/make-dmg.sh`：DMG 内容和文件名。

本地检查：`actionlint`、`bash -n scripts/render-cask.sh scripts/release-notes.sh mac/scripts/make-dmg.sh`、`uv run --no-project python -m unittest discover -s scripts/tests -v`。
