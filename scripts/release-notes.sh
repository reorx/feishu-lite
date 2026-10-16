#!/bin/bash
set -euo pipefail
revision=${1:?Usage: release-notes.sh BACKEND_REVISION}
[[ "$revision" =~ ^[a-zA-Z0-9._-]+$ ]] || exit 1
cat <<EOF
适用于 macOS 14 及以上，支持 Apple Silicon 和 Intel。App 已使用 Developer ID 签名并通过 Apple 公证。

## Homebrew 安装（推荐）

\`\`\`sh
brew install --cask reorx/tap/feishu-lite
\`\`\`

Cask 自动安装 uv、Git 和与 App 对应的 Python 后端。升级前退出 App，运行 \`brew upgrade --cask feishu-lite\` 后重新打开。Cask 在 Release 发布后自动更新，首次发布时可能需要稍等片刻。

## 从 FeishuChat 升级

升级前取消旧 App 的开机启动并退出；新 App 需要重新允许通知、开启开机启动，邮件钥匙串可能要求授权。原登录和聊天/邮件缓存原地保留，不删除数据。Homebrew 自动替换旧 App；手动安装后可把旧 FeishuChat.app 移到废纸篓。旧通知可手动清除。

## 手动安装 DMG：使用前必须安装依赖

FeishuLite 依赖独立的 Python 后端 **feishu-lite-backend**，其中通过 **larkx** 连接飞书。DMG 不包含 Python 或这些依赖；只安装 App 还不能使用。

1. 安装 [Homebrew](https://brew.sh/zh-cn/)（如已安装可跳过）。
2. 打开终端，安装 uv 和 Git：

\`\`\`sh
brew install uv git
\`\`\`

3. 安装与本版本对应的后端（升级 App 时也请执行）：

\`\`\`sh
uv tool install --force --python 3.12 'git+https://github.com/reorx/feishu-lite.git@$revision#subdirectory=backend'
\`\`\`

uv 会自动安装 Python 3.12 和所需库。首次安装需要联网访问 GitHub 和 Python 包源，可能需要几分钟。

4. 下载 DMG，将 FeishuLite 拖到 Applications，打开后用手机飞书扫码登录。

如果先打开 App，缺少依赖时会显示安装说明；安装后点击「已安装，重新检测」即可，无需重启 App。使用 uv 默认安装位置（\`~/.local/bin\`），App 从 Finder 启动也能找到后端。

登录凭证和缓存保存在本机。FeishuLite 使用逆向网页版协议，并非飞书官方客户端。
EOF
