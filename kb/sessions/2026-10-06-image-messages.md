---
created: 2026-10-06
tags:
  - images
  - backend
  - swiftui
---

# 实现独立图片消息展示

## 概要

检查发现原先只支持发送文本，所有图片消息都显示 `[图片]`。本次增加独立图片消息的缩略图、点击大图、缩放、失败重试及不可用提示，发送图片保持未实现。

后端新增受现有 Bearer token 保护的 `GET /messages/{message_id}/image`。按缓存里的会话和消息位置重新拉取协议内容，确认资源尚未撤回，复用固定版本 larkx 的图片 key 解析和带凭证下载。这样旧缓存不需迁移，历史消息、实时消息共用一条下载链路。预览和通知仍显示 `[图片]`，获取图片不调用已读接口。

## 修改的文件

- `backend/src/feishu_lite/source.py`：新增 Source 图片下载能力，支持 origin、imageKey 和 imageV2。
- `backend/src/feishu_lite/service.py`：确认登录和缓存消息类型，校验下载内容的图片格式及像素上限。
- `backend/src/feishu_lite/api.py`：新增图片接口及 404/409/502 响应，禁止 HTTP 缓存。
- `backend/pyproject.toml`、`backend/uv.lock`：显式声明用于图片校验的 Pillow 依赖，larkx commit 未变。
- `mac/FeishuChatCore/Sources/FeishuChatCore/Models.swift`：增加可展示图片的判断，兼容旧消息 JSON。
- `mac/FeishuChat/Services/BackendClient.swift`、`Model/Conversation.swift`：通过当前后端连接拉取图片，兼容后端重启后的端口/token 变化。
- `mac/FeishuChat/UI/ConversationView.swift`、`ImageMessageView.swift`：图片气泡、固定加载占位、大图弹层、缩放和重试。
- 后端 `test_images.py`、Swift `ImageMessageTests.swift`：先写失败测试，再实现；覆盖鉴权、旧缓存、实时推送、三种图片 key、撤回/缺失、无效内容、失败重试和凭证失效。
- `AGENTS.md`、`kb/known-issues.md`：同步功能现状及真实环境验收缺口。

## 验证

- `cd backend && uv run pytest`：39 项通过。
- `cd mac && make test`：47 项通过。
- `cd mac && make build`：成功。环境的 Xcode/CoreSimulator 版本警告不影响 macOS 构建；未启动模拟器。
- 使用本地 FakeSource、隔离 SQLite 和生成的测试图片运行完整 App，未读取真实凭证或访问真实工作会话。
- 已验证左右图片气泡、旧消息 JSON、撤回文字提示、下载失败提示、重试成功、大图预览和放大按钮。
- 截图归档：`tmp/2026-10-06-image-messages/`，其中 `messages.png`、`preview.png`、`zoom.png`、`retry.png` 为验收证据。脚本与测试数据库也在此目录，不入库。
- 截图前运行仓库文档指定的 wake-screen；辅助验证工具缺失时，以 AX 和实际截图确认屏幕可用。最终截图仅保留 App 窗口。
- 验收完成关闭测试 App 和本地后端；`mac-dev-cleanup --only browser --min-age 2` 检查无可清理浏览器。

## 注意事项

- 不将飞书 cookie 或资源 URL 交给 SwiftUI，不将下载图片写入磁盘。图片随视图驻留内存，重新打开会话会重新下载。
- 飞书文件服务可能返回 `application/octet-stream`，因此用实际文件格式确定响应 MIME；HTML 登录页等内容不能作为图片返回。
- 单张下载限 25 MiB，图片限 4000 万像素。加载前重新读取消息，可拒绝已撤回资源；本次未增加实时撤回事件订阅。
- 大图从已经加载的原图打开，放大后可水平/垂直滚动，Esc 可关闭。

## 遗留问题

- 当前机器无飞书登录凭证，真实文件服务下载尚未验收，已登记 known issues。
- 图片发送、富文本内嵌图片不在本次实现范围，GIF 动画播放未验收。

## 相关文档

- [已知问题](../known-issues.md)：更新图片能力边界与真实环境验收缺口。
- [MVP App 与验收](2026-10-01-feishu-chat-app-and-acceptance.md)：参考现有界面和桌面验收方式。
