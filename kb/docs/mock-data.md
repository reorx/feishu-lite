---
created: 2026-10-21
tags: [testing, mock-data]
---

# 用模拟数据运行 Debug App

界面调整后的截图对比、演示和自动化验收优先使用模拟模式。它使用真实的 REST/SSE、SQLite、聊天服务、邮件同步和 HTML 净化流程，只把飞书和 IMAP 数据源换成本地 JSON。无需扫码或邮箱密码，不连接真实账号。

## 启动与退出

在仓库根运行：

```sh
make -C mac run-mock
# 自定义场景与构建目录
make -C mac run-mock MOCK_DATA="$PWD/mock-data/showcase" DERIVED_DATA="$PWD/tmp/my-test/DerivedData"
# 已构建的 Debug App
open -n --env FEISHU_LITE_MOCK_DATA="$PWD/mock-data/showcase" "$PWD/tmp/my-test/DerivedData/Build/Products/Debug/FeishuLite.app"
```

`run-mock` 默认构建到 `tmp/mock-build/DerivedData`，不会覆盖日常 Debug 构建，也不会结束任何已有实例。每次调用会新开一个模拟实例；验收后请按自己记录的 PID 退出，不要按进程名批量结束。

App 只在 Debug 读取该变量。相对场景路径相对于配置中 backend 目录的上一级；绝对路径更适合脚本。模拟配置优先于外部后端和 `FEISHU_LITE_HOME`。后端 CLI 也支持 `--mock-data DIR`，需要 `FEISHU_LITE_TOKEN`，仅监听回环地址。

目录错误或 JSON 错误会让后端退出，App 显示后端失败并按原策略重试。模拟日志在系统临时目录的 `feishu-lite-mock-<App PID>.log`，包含场景文件、字段或目录错误；不写日常后端日志。

## 场景格式

标准样本在 `mock-data/showcase/`，复制整个目录即可增加场景。临时变体放 `tmp/`。模型定义见 `backend/src/feishu_lite/mock.py`；测试不绑定 showcase 的具体文字、人数或条目数量。

目录可以缺 `messages.json` 或 `emails.json`：缺聊天时显示在线的空聊天列表，缺邮件时显示未配置。目录本身必须存在。文件都存在时，两边均直接在线。

所有 `time` 接受 Unix 秒整数，或 `{"day": -1, "time": "09:30"}`。`day` 是相对于启动当天的天数，0 今天、-1 昨天，钟点为本机时区的 24 小时制。每次加载固定一个基准日期。

### messages.json

顶层字段：`me` 是 `{id, name}`，`users` 是其他联系人数组，`chats` 是会话数组。所有发送者必须出现在 me/users，用户、会话和消息 id 不能重复。

会话字段：`id`、`name`，可选 `type`（`p2p` / `group`，默认 group）、`unread`（默认 0）、`muted`（默认 false）、`messages` 数组。消息数组按历史顺序排列，自动生成连续 position；列表按最后一条消息时间排序。

消息字段：`id`、`sender_id`、`time`，可选 `type`（默认 text）、`text`、`badged`、`at_me`。本人身份由 sender_id 判断。

- `text`：普通或多行文本，JSON 中用 `\n` 换行。
- `post`：已渲染的富文本纯文字。
- `system`：系统提示，不计未读。
- `image`：必须给 `image: "images/sample.png"`。文件必须存在，解析后的路径须在本场景 images/ 内。通过真实鉴权图片接口按需读取，支持 PNG/JPEG 等 App 已支持的格式。
- `video_chat`：必须给 `meeting: {"topic": "讨论", "number": "123456789"}`。number 必须是 9 位数字字符串，由数据源生成会议号和入口文本。

### emails.json

顶层字段：`address`、`folders`、`messages`。folders 的每项是 `{id, name}`，必须包含 `{"id":"INBOX","name":"收件箱","supported":true}`。其他文件夹只列出，不支持阅读，与真实 App 一致。

每封邮件：`uid`（正整数、唯一，越大越新）、`time`、`body: {kind, source}`。kind 是 `html` 或 `plain`。HTML 仍经过真实净化器和隔离 WebKit，不允许远程资源。

可选字段：`subject`、`sender`、`to`、`cc`（后三项都是 `{name, address}` 数组）、`date`、`message_id`、`unread`（默认 true）、`attachments`。附件只展示元信息；每项有 `section`、`media_type`，可选 `filename`、`encoded_size`、`size_is_approximate`、`content_id`。邮件地址使用 example.com 等保留域。

## 隔离与限制

每个后端进程使用全新临时目录。目前正常 SIGTERM 退出也可能留下目录（T1 待修），确认自己的后端已退出后，按模拟日志中的精确路径删除。读、发、已读只改变此次运行的内存和缓存，不改场景文件；重启恢复初始数据。模拟入口不 import larkx，也不调用真实数据目录准备逻辑。邮箱首次同步作为历史导入，不产生提醒批次。

每个模拟 App 使用独立随机 UserDefaults 域，模块选择、隐藏会话、邮件通知意图和凭证清理记录均隔离，正常退出删除。跳过旧域迁移；凭证存储为空实现；不申请通知授权、不投递或删除系统通知、不写 Dock badge；登录项读写被禁用。异常强退可能留下随机偏好域或临时目录，按此次 PID 和日志中路径清理。

同 bundle id 的 SwiftUI/AppKit 系统窗口恢复、窗口尺寸等偏好可能共享；隔离保证针对 App 自己的业务键，不能承诺系统管理的窗口键完全不变。系统临时日志保留便于排障，验收归档后可删除。

## 自动截图

先记录本次 App PID，核对可执行文件在自己的构建目录。先运行 `wake-screen`，再用 CGWindowList 按该 PID 找 layer 0 的窗口 id，运行 `screencapture -x -o -l <窗口id> <文件.png>`。只截自己窗口，不截整个桌面。长轮次使用 `caffeinate -d`，结束后清理自己的进程。AX 选择行可用；输入消息应使用真实键入，不能仅用 AX 设置文本值。

截图和 AX 证据须归档 `tmp/<date>-<task>/`。关闭自己的 App 后确认后端退出、临时数据库目录已移除，保留证据和所需日志。
