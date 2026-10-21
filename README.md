<p align="center">
  <img src="mac/Artwork/AppIcon.png" alt="FeishuLite" width="160">
</p>

<h1 align="center">FeishuLite</h1>

<p align="center">一个只用来聊天的轻量飞书 macOS 客户端</p>

飞书官方客户端里装着文档、日历、会议和工作台。如果你在电脑上用飞书主要是为了收发消息，可以试试 FeishuLite。用手机飞书扫码登录后，就能在电脑上查看会话、回复消息，有新消息时收到系统通知。

<table>
  <thead><tr><th>Messages</th><th>Email</th></tr></thead>
  <tbody><tr>
    <td><picture>
      <source media="(prefers-color-scheme: dark)" srcset="mac/Artwork/screenshots/messages-dark.png">
      <img src="mac/Artwork/screenshots/messages-light.png" alt="Messages：团队群聊、图片消息与视频会议邀请" width="380">
    </picture></td>
    <td><picture>
      <source media="(prefers-color-scheme: dark)" srcset="mac/Artwork/screenshots/email-dark.png">
      <img src="mac/Artwork/screenshots/email-light.png" alt="Email：收件箱与包含表格、列表和附件信息的 HTML 周报" width="380">
    </picture></td>
  </tr></tbody>
</table>

截图中的人物、团队及内容均为虚构展示数据。

## 功能

- 查看单聊和群聊，往上翻可以看到更早的消息
- 发送文字消息
- 新消息实时到达，弹出系统通知，Dock 图标显示未读数
- 查看图片消息，点开可以放大
- 视频会议邀请显示会议主题和会议号，点一下就能入会
- 隐藏暂时不想看的会话，之后随时恢复
- 关掉窗口后仍在后台接收消息，可以设置开机启动
- 查看飞书邮箱的收件箱，支持 HTML 和纯文本邮件，新邮件弹出提醒

## 安装

需要 **macOS 14 或更新版本**，支持 Apple Silicon 和 Intel。

用 Homebrew 安装：

```sh
brew install --cask reorx/tap/feishu-lite
```

运行所需的 uv、Git、Python 3.12 和后端会一起装好，安装过程需要联网。升级前先退出 FeishuLite，运行 `brew upgrade --cask feishu-lite`，完成后重新打开。卸载 FeishuLite 不会删除你的登录信息、消息和邮件缓存。

### 手动安装 DMG

从[本仓库 Releases](https://github.com/reorx/feishu-lite/releases) 下载 DMG，把 FeishuLite 拖进「应用程序」。App 经过 Apple 公证。

App 里不带 Python 运行环境，手动安装时还要单独装一次后端：

1. 安装 [Homebrew](https://brew.sh/zh-cn/)（已有就跳过），然后在终端运行 `brew install uv git`。
2. 在下载 DMG 的那个 Release 页面上，复制后端安装命令，粘贴到终端运行。命令里带着和这个版本对应的提交号，请复制完整的命令。

还没装后端就打开 App 的话，窗口里会显示安装说明和可以复制的命令，装好后点「已安装，重新检测」。以后升级 App 时，也要运行新版本 Release 页面上的后端安装命令。

## 使用

1. 打开 FeishuLite，用手机飞书扫描窗口里的二维码，在手机上确认登录。
2. 在左侧选择一个会话。输入文字后按回车发送，按 Shift + 回车换行。
3. 系统询问是否允许通知时，选择允许。如果之前拒绝过，可以在「系统设置 → 通知 → FeishuLite」里打开。
4. 想让 FeishuLite 开机自动运行，在菜单栏的应用菜单里勾选「开机启动」。

在侧栏顶部切换 Messages 和 Email，也可以按 ⌘1、⌘2。来回切换不会丢掉正在看的会话和还没发出的草稿，下次打开 App 时会回到上次所在的模块。

在 FeishuLite 里打开一个会话会把它标为已读，手机上的未读也会一起清掉。只有窗口在前台、正看着这个会话时才算已读，挂在后台不会。

### 邮箱

第一次切到 Email 时按提示配置：填飞书邮箱地址和「第三方客户端专用密码」。邮箱和扫码登录的聊天账号分开配置，密码保存在 macOS 钥匙串里。如果 Email 提示需要更新后端，按提示重新安装后端即可。

- 目前只能读收件箱，不能写信。按 ⌘R 刷新。
- 正文显示出来才会标为已读。看过的邮件断网时也能打开。
- 为了安全，HTML 邮件里的图片和其他远程内容不会加载，点链接会在浏览器里打开。附件只显示名称和大小，不能下载。
- 新邮件到达时弹出通知，点通知跳到对应的邮件；几封合在一条通知里时，跳到收件箱。如果 App 意外退出，没来得及确认通知是否弹出过，Email 里会出现「再次提醒」，再提醒一次可能会和之前的重复。

目前还不能发送图片和文件，也不能写邮件；音视频会议、云文档等功能也没有，用到这些时请打开官方客户端。

FeishuLite 不是飞书官方产品，它使用和飞书网页版相同的方式连接飞书，飞书更新后可能会暂时无法使用。登录信息、消息和邮件缓存只保存在你自己的电脑上，不经过任何第三方服务器。

## Reference

- [cv-cat/LarkAgentX](https://github.com/cv-cat/LarkAgentX)：逆向实现的飞书网页版协议。FeishuLite 的扫码登录和消息收发都基于它的 larkx 库。
- [EthanQC/feishu-user-plugin](https://github.com/EthanQC/feishu-user-plugin)：FeishuLite 定时刷新登录状态的做法参考了它。
