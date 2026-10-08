#!/bin/bash
set -euo pipefail
revision=${1:?Usage: release-notes.sh BACKEND_REVISION}
[[ "$revision" =~ ^[a-zA-Z0-9._-]+$ ]] || exit 1
cat <<EOF
适用于 macOS 14 及以上，支持 Apple Silicon 和 Intel。App 已使用 Developer ID 签名并通过 Apple 公证。

## 使用前必须安装依赖

FeishuChat 依赖独立的 Python 后端 **feishu-lite-backend**，其中通过 **larkx** 连接飞书。DMG 不包含 Python 或这些依赖；只安装 App 还不能使用。

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

4. 下载 DMG，将 FeishuChat 拖到 Applications，打开后用手机飞书扫码登录。

如果先打开 App，缺少依赖时会显示安装说明；安装后点击「已安装，重新检测」即可，无需重启 App。使用 uv 默认安装位置（\`~/.local/bin\`），App 从 Finder 启动也能找到后端。

登录凭证和缓存保存在本机。FeishuChat 使用逆向网页版协议，并非飞书官方客户端。
EOF
