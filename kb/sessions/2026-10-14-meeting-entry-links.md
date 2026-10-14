---
created: 2026-10-14
tags: [chat, meetings, links]
---

# 视频会议入口链接附带会议号

## 概要

用户确认飞书网页入口支持 `https://vc.feishu.cn/w/<会议号>`。会议邀请正文中的入口现在在公开九位会议号有效时附加原始数字串；正文仍以空格分组显示会议号。缺少有效会议号时保留基础入口。

## 修改的文件

- `backend/src/feishu_lite/render.py`：从 `meetNumber` 生成携号入口；不用内部 `meetingId`。
- `backend/tests/test_render.py`、`backend/tests/test_meeting_cache.py`：更新入口行为期望，覆盖会议号格式。
- `AGENTS.md`：更新会议入口约定并指向本记录。

## 验证

- 先更新预期 URL 后运行定向测试，旧实现按预期失败。
- `cd backend && uv run pytest tests/test_render.py tests/test_meeting_cache.py -q`：21 项通过。

## 注意事项

URL 用未分组的数字，正文显示用分组数字；链接路径取 `meetNumber`，不能取内部 `meetingId`。

## 遗留问题

无。
