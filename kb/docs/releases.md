---
created: 2026-10-16
tags: [release, homebrew, macos]
---
# 发布 FeishuLite

用户通过 `brew install --cask reorx/tap/feishu-lite` 安装。下一版 Cask 安装 FeishuLite.app，同时安装 uv、Git 及与 App 对应 commit 的 Python 后端。v0.1.0 已发布到 GitHub Releases 和 tap，仍为 FeishuChat.app；不得重打该 tag 或替换旧产物。DMG 用户按照 Release 页说明手动安装后端。

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

2026-10-16 已从该目录同步六项签名 Secrets，并用本机 `gh auth token` 经 stdin 配置 TAP_PUSH_TOKEN，确认有 tap 写权限。当前复用的是 GitHub CLI OAuth token，拥有 `repo` 等账号级权限，并非仅限 tap 的 fine-grained PAT；以后更换凭据可使用上表的最小权限 PAT。v0.1.0 已通过 Apple 公证、staple 和 Gatekeeper 验证，历史协议 403 未重现。没有成功公证的包不会上传或发布。

## 验证与正式发布

先提交并推送当前分支。默认分支上的试运行：

```sh
gh workflow run release.yml --ref master
gh run list --workflow release.yml
```

确认测试、签名、公证、Gatekeeper 与 artifact 上传均成功后，发布下一个版本（以下以 0.1.1 为例，0.1.0 已发布）：

```sh
git tag v0.1.1
git push origin v0.1.1
```

等待 Release 和 Homebrew 两个 job 均成功，在干净用户环境验证安装、Finder 启动、后端就绪和升级。不要用正式聊天会话做点击验收。

如果仅 Homebrew job 失败，修复 Token 或 tap 冲突后使用 GitHub 的 Re-run failed jobs。它下载已发布 DMG，无需重做签名和公证。已存在同版本 Cask 且内容一致时不会提交；tap 有更新版本时会拒绝降级。Release 同版本重试会替换产物，因此尽量只重试失败 job，正式修复优先发新版本。

## 安装和卸载边界

安装与升级需要访问 GitHub、Python 下载源和包源。uv 安装失败会使 Cask 安装报错，网络恢复后可 `brew reinstall --cask reorx/tap/feishu-lite` 重试。升级前退出 FeishuLite，避免正在运行的后端与磁盘版本不一致。

后端入口固定安装到当前用户 `~/.local/bin`，Finder 启动可发现；Cask 为当前用户安装后端，不为其他 macOS 用户预装。普通卸载保留登录、消息、邮箱和 uv 后端，不添加会清空数据的 zap。需要单独卸载后端时执行 `uv tool uninstall feishu-lite-backend`。

Cask 使用第三方 tap 仍兼容的 Ruby `postflight`，用于调用需要联网和用户目录写入的 uv 安装。当前 Homebrew 会提示该钩子弃用；后续迁移到结构化 `postflight_steps` 时需声明网络权限和 uv 的写目录，并实际复验沙箱中的 Python/Git 下载，不能只替换 DSL 名称。官方规则见 [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-flight_steps)。

## 实现与检查

- `.github/workflows/release.yml`：构建、签名、公证、发布、tap 更新。
- `scripts/render-cask.sh`：版本 / SHA256 / commit 校验及 Cask 生成。
- `scripts/tests/`：元数据与安装/升级钩子的隔离行为验证。
- `scripts/release-notes.sh`：Cask 和 DMG 安装说明。
- `mac/scripts/make-dmg.sh`：DMG 内容和文件名。
- `mac/Config/Release.xcconfig`：禁用基础调试权限注入；`get-task-allow` 会导致 Apple 拒绝公证，不能删除这项配置。

本地检查：`actionlint`、`bash -n scripts/render-cask.sh scripts/release-notes.sh mac/scripts/make-dmg.sh`、`uv run --no-project python -m unittest discover -s scripts/tests -v`。

## 从 FeishuChat 升级

下一版原生客户端为 **FeishuLite.app / com.reorx.FeishuLite**，工程及 Swift 包也统一使用 FeishuLite。安装命令和 Cask token `feishu-lite` 不变；新的 DMG 为 `FeishuLite-<version>.dmg`。`render-cask.sh` 对已发布的 0.1.0 保留旧 app/DMG 名称。线上 tap 在下一版本成功发布后才更新，目前仍提供原版 0.1.0。

升级前退出 FeishuChat 和 FeishuLite，避免两份后端同时使用同一缓存。Homebrew 使用已安装旧 Cask 的 app artifact 卸载/暂存 FeishuChat，再安装新 Cask 的 FeishuLite；无需额外删除钩子，也不添加 zap。手动 DMG 用户在退出旧 App、取消旧 App 的「开机启动」后，将新 App 拖入 Applications，再把旧 FeishuChat.app 移到废纸篓；不要删除 Application Support 或钥匙串。

- **登录和数据库**：保留 `~/Library/Application Support/FeishuChat/` 作为稳定存储命名空间，原 larkx 凭证、cache.db、mail.db 原地使用，不复制或改名 SQLite，也不合并两套数据。`FEISHU_LITE_HOME` 覆盖仍有效。旧版回退继续读取同一目录。
- **偏好**：新 App 在模型创建前，从 `com.reorx.FeishuChat` UserDefaults 域一次性补齐缺失值，保留隐藏会话、当前模块、邮件通知 receipt/intent 与待清理凭证 UUID。新值优先，旧域不删除；以后删除新偏好不会再次从旧域复活。草稿本来只在内存中，退出前先处理未发送内容。
- **邮件密码**：继续使用 Release `com.reorx.FeishuChat.mail` / Debug `.mail.debug`，精确 account UUID 和双配置隔离不变。这些是存储标识，不是 bundle ID。旧钥匙串 ACL 可能要求允许新 App 访问，拒绝时应用原有错误/重试/重新输入流程；不批量删密码、不跨配置读取、不导出明文。
- **通知与登录项**：新 bundle 是新的系统身份，需要重新允许 FeishuLite 通知、在新 App 菜单勾选开机启动。升级前先在旧 App 取消开机启动，或在系统设置「通用 → 登录项」移除旧项。不能通过新 bundle 的 `SMAppService.mainApp` 替旧 App 注销；不冒用旧身份。旧通知不会迁移或自动清理，用户可手动清除，旧通知点击也不会转交新 App。
- **日志**：新日志写入 `~/Library/Logs/FeishuLite/backend.log`，旧日志保留供排障。

改名的本地验证与边界见 [改名记录](../sessions/2026-10-16-feishulite-rename.md)。正式签名、公证和从 0.1.0 的完整 Homebrew 升级需在下一版发布时验证。
