<p align="center">
  <img src="mac/Artwork/AppIcon.png" alt="FeishuLite" width="160">
</p>

<h1 align="center">FeishuLite</h1>

<p align="center">一个只用来聊天的轻量飞书 macOS 客户端</p>

飞书官方客户端里装着文档、日历、会议和工作台。如果你在电脑上用飞书主要是为了收发消息，可以试试 FeishuLite。用手机飞书扫码登录后，就能在电脑上查看会话、回复消息，有新消息时收到系统通知。

## 功能

- 查看单聊和群聊，往上翻可以看到更早的消息
- 发送文字消息
- 新消息实时到达，弹出系统通知，Dock 图标显示未读数
- 查看图片消息，点开可以放大
- 隐藏暂时不想看的会话，之后随时恢复
- 关掉窗口后仍在后台接收消息，可以设置开机启动
- Messages / Email 独立切换；开发版本已实现邮箱配置、后台同步、收件箱分页、HTML/纯文本阅读、附件信息及邮件提醒；主要邮箱 UI 与 WebKit 隔离已有独立证据；HTML 滚动恢复及新增内存文档隔离已通过独立复验，测试 UUID 双配置钥匙串隔离与主要系统提醒已独立验证，真实邮箱和少量系统边界仍待验

## 安装

需要 **macOS 14 或更新版本**，支持 Apple Silicon 和 Intel。

直接运行：

```sh
brew install --cask reorx/tap/feishu-lite
```

Cask 自动安装 uv、Git、Python 3.12 和与 App 对应的后端。安装时需要联网访问 GitHub 和 Python 包源。升级前退出 App，再运行 `brew upgrade --cask feishu-lite`，完成后重新打开。卸载 Cask 会保留登录、消息、邮件数据及 uv 后端。

### 手动安装 DMG

从[本仓库 Releases](https://github.com/reorx/feishu-lite/releases) 下载 DMG，将 FeishuLite 拖到 Applications。发布包经过 Developer ID 签名和 Apple 公证。

**使用前必须安装 Python 后端 `feishu-lite-backend`**。App 本身不包含 Python 或 `larkx` 等依赖：

1. 安装 [Homebrew](https://brew.sh/zh-cn/)（已有则跳过），在终端运行 `brew install uv git`。
2. 复制对应 Release 页面提供的 `uv tool install --force --python 3.12 'git+https://github.com/reorx/feishu-lite.git@<版本对应的 commit>#subdirectory=backend'` 命令执行。请使用 Release 中的完整命令，不要原样输入占位符。
3. uv 会自动安装 Python 3.12、后端和固定版本的 `larkx`。安装需要联网访问 GitHub 和 Python 包源。

如果直接打开 App 而尚未安装后端，会显示安装说明和可复制命令。安装完点击「已安装，重新检测」即可。后端默认安装到 `~/.local/bin`，无需修改 Finder 的 PATH；升级 App 时也请执行新 Release 中的后端安装命令。

## 使用

1. 打开 FeishuLite，用手机飞书扫描窗口里的二维码，在手机上确认登录。
2. 在左侧选择一个会话。输入文字后按回车发送，按 Shift + 回车换行。
3. 系统询问是否允许通知时，选择允许。如果之前拒绝过，可以在「系统设置 → 通知 → FeishuLite」里打开。
4. 想让 FeishuLite 开机自动运行，在菜单栏的应用菜单里勾选「开机启动」。

在前台可见的 Messages 工作区打开一个会话会把它标为已读，手机上的未读也会一起清掉。停留在 Email 时，之前选中的聊天继续同步，但不会因为旧选择被自动标为已读；切回 Messages 后补判已读。

切换模块保留当前聊天与草稿，并记住当前模块供重启恢复。两处首可见行恢复与 Email 页键盘隔离已通过独立隔离 UI 验收；主要系统通知投递/点击已通过 [F2a验收](kb/sessions/2026-10-14-email-system-notifications-f2a.md)；[F2c报告](kb/sessions/2026-10-14-email-keychain-chat-f2c.md)补齐合成隐藏取消/扫码状态及邮箱错误期间聊天历史、键入后点击发送与草稿；中文 IME、Return 自动化和少量系统边界仍未验。

Email 配置使用飞书邮箱地址及第三方客户端专用密码，与聊天扫码账号独立。支持邮箱功能的后端才显示配置；旧版本会提示重新安装后端。密码按邮箱账号存入 macOS 钥匙串，后端重启通过内存凭证恢复；写入失败会明确提示退出后需要重新输入，并提供重试。旧账号密码删除失败的清理记录跨 App 重启保留。配置及模拟凭证错误UI已通过隔离验收；真实测试 UUID 的钥匙串自身读写与凭证恢复调用已验证；旧共享 service 跨签名互访曾要求系统密码，现按 Debug/Release 区分 service，Release 保留旧名，Debug 缺失须重新输入且不迁移；新测试 UUID 双配置真实隔离已通过 [F2c报告](kb/sessions/2026-10-14-email-keychain-chat-f2c.md)，历史 ACL、真实拒绝/锁定及真实邮箱仍未验。实现契约见 [D1 报告](kb/sessions/2026-10-13-email-configuration-d1.md)。

Email 列出全部文件夹，首版仅读取收件箱。正文成功显示且 App 位于前台、窗口可见、当前处于 Email 时才提交已读；离线可读已缓存正文，失败不会清未读。HTML 禁止页面脚本与资源加载，合法 HTTP(S) 用户链接交外部浏览器；附件只显示信息。主要配置/阅读、实际 WebKit 资源隔离及可见性已读已通过隔离验收；HTML 滚动恢复及新增内存文档隔离已通过 [F1b独立复验](kb/sessions/2026-10-14-email-reader-f1b-acceptance.md)，同时补齐浅色/鼠标拖宽/cursor恢复和模拟凭证错误UI；纯文本滚动与原生只读正文主要交互已通过 [F1c独立复验](kb/sessions/2026-10-14-email-reader-f1c-acceptance.md)，回顶P2关闭；真实中文组字及精确旧layout仍未验；未知能力/部分精确竞态、历史钥匙串 ACL 及真实跨端已读仍待验。

邮件提醒按后端批次逐封或汇总，点击进入对应邮件或收件箱；睡眠唤醒后重连对账。成功投递记录防止确认失败时重复提醒。若 App 中断后无法确认投递结果，会保留待提醒邮件，Email 显示“再次提醒”入口，并说明可能重复显示；不会把未知结果当成功确认。通知、清理、路由及唤醒通过隔离自动测试与 Debug 构建，主要实际系统弹出/点击已由F2a验证，未知投递提示布局P2已由F2b关闭；隔离生产后端生命周期与合成唤醒事件通过，机器真实睡眠恢复仍未验，见 [F2b报告](kb/sessions/2026-10-14-email-system-integration-f2b.md)。

目前还不能发送图片和文件，也没有音视频会议、云文档等功能，用到这些时请打开官方客户端。

FeishuLite 不是飞书官方产品，它使用和飞书网页版相同的方式连接飞书，飞书更新后可能会暂时无法使用。登录信息和消息缓存只保存在你自己的电脑上，不经过任何第三方服务器。

## 构建和发布

普通 push / PR 会运行后端测试、独立 Python 工具安装验证、Swift 测试，以及 Debug / Universal Release 构建。发布配置见 [.github/workflows/release.yml](.github/workflows/release.yml)。

推送 `vMAJOR.MINOR.PATCH` 标签会构建 Universal DMG、签名、公证，上传到**当前仓库**的 GitHub Releases，然后自动创建或更新 `reorx/homebrew-tap` 的 `Casks/feishu-lite.rb`。手动运行 Release 工作流只生成可下载 artifact（即使选择 tag 也不发布）。

签名使用 `CERT_P12`、`CERT_P12_PASSWORD`、`APPLE_TEAM_ID`、`ASC_PRIVATE_KEY`、`ASC_KEY_ID`、`ASC_ISSUER_ID` 六个仓库 Secrets；证书和私钥使用 base64 编码。Cask 发布另使用 `TAP_PUSH_TOKEN`。七项均已配置，`v0.1.0` 已通过完整发布流程。更换 Token 时建议仅授予 `reorx/homebrew-tap` 的 Contents 读写权限；缺少 Token 时 Cask job 明确失败，可补齐后仅重跑失败 job。凭据来源和完整步骤见 [发布指南](kb/docs/releases.md)。

本地使用 `make -C mac test`、`make -C mac build-release`、`make -C mac dmg`；签名需要本机 Developer ID 证书和 `RELEASE_XCARGS='DEVELOPMENT_TEAM=你的TeamID'`。开发调试仍使用 `make -C mac build` 和源码后端。

## Reference

- [cv-cat/LarkAgentX](https://github.com/cv-cat/LarkAgentX)：逆向实现的飞书网页版协议。FeishuLite 的扫码登录和消息收发都基于它的 larkx 库。
- [EthanQC/feishu-user-plugin](https://github.com/EthanQC/feishu-user-plugin)：FeishuLite 定时刷新登录状态的做法参考了它。

### 从 FeishuChat 升级

当前源码已改名为 **FeishuLite**（bundle ID `com.reorx.FeishuLite`）；已发布的 v0.1.0 仍叫 FeishuChat，下一版才提供新名称。安装命令不变。

升级前先取消旧 App 的开机启动并退出旧 App；新 App 需要重新允许通知、开启登录项，邮件钥匙串可能要求授权。原登录和聊天/邮箱缓存继续保存在 `~/Library/Application Support/FeishuChat/`，不会清空。手动安装用户可在退出后将旧 FeishuChat.app 移到废纸篓。详见[升级说明](kb/docs/releases.md#从-feishuchat-升级)。
