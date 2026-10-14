---
created: 2026-10-14
tags: [chat, meetings, protocol]
title: 视频会议邀请显示会议号和网页入口
---

# 视频会议邀请显示会议号和网页入口

## 概要

会议消息（类型 19）原先直接显示 `[视频会议]`。只读查询用户指定群的最新会议邀请后，确认原始 protobuf 带有主题和公开会议号，但没有 HTTP(S) URL。改为使用 larkx 的完整实体模型解析，显示主题、按三位分组的九位会议号和 `https://vc.feishu.cn/w/` 网页入口。现有 SwiftUI 正文已经支持链接点击、文字选择与复制，无需修改 App 或 wire 模型。

## 修改的文件

- `backend/src/feishu_lite/render.py`：解析完整 `VideoChatContent`，显示公开会议号；空内容保留占位符。
- `backend/src/feishu_lite/store.py`：同 ID 的完整会议消息可补全旧占位文字，但仍返回“非新消息”，不覆盖已撤回或已补全内容。
- `backend/src/feishu_lite/service.py`：历史读取时补拉旧会议占位缓存；同一进程成功查询后不反复请求不可用的详情，登出清空尝试记录。feed 同步复用 Store 的补全逻辑。
- `backend/tests/test_render.py`、`backend/tests/test_meeting_cache.py`：先写复现测试，再实现解析、缓存更新与只读行为。
- `AGENTS.md`：记录会议展示和协议字段约定。

## 验证

- 修复前定向测试：7 项失败，复现会议详情丢失及旧缓存无法更新。
- 后端全量：310 项通过；随后增加撤回保护测试及登出清理，相关渲染/缓存/聊天行为测试重新通过，共 31 项。
- 真实协议内容再次解析：确认与用户截图中的会议号一致，且消息 bytes 不含 HTTP(S) URL。查询没有调用 mark_read、发送消息或操作真实群 UI。
- 缓存行为测试验证：历史接口补全后不重复请求、不调用已读、不增加未读、不产生 `message.new`；占位数据不能覆盖完整数据，完整数据不能恢复已撤回消息。
- 原始数据及只读探路脚本仅保存在 gitignore 的 `tmp/2026-10-14-meeting-invitation/`；提交测试使用虚构主题、会议号及 ID。
- 本次仅修改 Python 后端；未重启用户当前 App，以保留内存草稿。重启 App 后源码后端加载新实现，旧缓存自动补全。未进行 GUI 截图或实际入会。

## 注意事项

`proto_pb2.VideoChatContent` 是简化模型，没有 `meetNumber`；使用 `lark_all_pb2.entities.VideoChatContent` 才能读出字段 8。`meetingId` 是内部 ID，不能当作公开会议号或未经验证的网页路径。会议卡片没有 join URL 字段，因此只提供用户指定的网页入口，不推导专属入会地址，也不把缓存状态显示成实时会议状态。

## 遗留问题

无。本条邀请没有专属入会 URL，用户需在网页入口输入会议号。
