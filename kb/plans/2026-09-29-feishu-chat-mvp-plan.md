---
created: 2026-09-29
tags:
  - plan
  - feishu
  - swiftui
  - python
  - reverse-engineering
---

# FeishuChat MVP：基于逆向网页版协议的轻量飞书聊天客户端

背景和选型依据见 [调研笔记](../notes/2026-09-29-feishu-chat-access-research.md)。一句话总结：公司租户是免费版，官方 API 额度撑不起单聊的实时通知，所以走逆向网页版协议，协议层用 LarkAgentX 的 `larkx` 包。

## 0. 执行说明

- **执行者**：在 herdr 新 tab 里启动的 Claude agent。直接在 `~/Code/feishu-lite` 的 master 分支上工作，不开 worktree。
- **开始前先读**：本计划、调研笔记、`AGENTS.md`、`~/.claude/skills/macos-app-bootstrap/SKILL.md`。larkx 源码 clone 到 `tmp/refs/` 里读，**不要** clone 到 `~/Documents`（那里是 iCloud 同步目录）。
- **本计划的作者**：上一个 session 的 Claude，和用户讨论后写的。下表"已定决策"里标了"用户"的项不要重新讨论。标了"计划作者"的项，如果你有更好的理由可以改，但要写进最后的 session 总结里说明。
- **完成标准**（全部满足才算完成）：
  1. `cd backend && uv run pytest` 全部通过；`cd mac && make test && make build` 全部通过。
  2. 第 8 节验收清单的第 1 到第 8 项都用真实账号跑过，每项都有截图或命令输出作证据。第 9 项写进 `kb/next-up.md`。没通过的项写进 `kb/known-issues.md`，并在总结里说明。
  3. 写好 session 总结（`/kb ss`），AGENTS.md 已更新，代码已提交。
- **不要等人确认，一路做下去。** 只有需要用户扫码、需要用户在手机上发消息、或者遇到必须由用户做的决定时才停下来问。
- **范围外的问题**（larkx 上游的 bug、协议限制、想到的改进点）：写进 `kb/known-issues.md`（本项目有缺陷时）或总结的"后续建议"一节，不要顺手去改范围外的东西。

### 已定决策

| 问题 | 决定 | 谁定的 |
|---|---|---|
| 官方 API 还是逆向协议 | 逆向网页版协议（larkx） | 用户 |
| 界面形态 | 原生 SwiftUI App | 用户 |
| 项目位置 | `~/Code/feishu-lite` | 用户 |
| 测试粒度 | 粗粒度行为测试，不追求细 | 用户 |
| 通知 | 只要 Mac 本地通知，延迟 1 分钟内可接受（目标几秒内） | 用户 |
| 后端守护方式 | 由 App 拉起子进程，不用 launchd | 计划作者 |
| 本地通信 | 127.0.0.1 上的 HTTP + SSE，Bearer token 鉴权 | 计划作者 |
| App 命名 | `FeishuChat` / `com.reorx.FeishuChat` | 计划作者 |
| 已读策略 | 打开会话时才标已读 | 计划作者 |

### 约束

- 只改 `~/Code/feishu-lite` 下的文件。不要改全局配置，也不要改 `~/Documents/pake-apps`。
- 每个阶段结束时提交一次；只 `git add` 自己改过的文件。**不要 push**（还没有 remote）。
- 按用户的全局规则：Python 用 uv，依赖用 `uv add` 加；scratch 脚本放 `tmp/`；验收截图存到 `tmp/<date>-<task>/`，并在总结里写出路径。
- 用完 agent-browser 或模拟器后，跑 `mac-dev-cleanup` 释放资源；App 和后端的测试进程不要留在后台。

## 1. 目标与范围

**要做（MVP）**
1. 扫码登录本人飞书账号，凭证在本地持久化，并能自动保活。
2. 会话列表：所有单聊和群聊，显示名称、最后一条消息预览、时间和未读数，按最近活跃排序。
3. 点进会话看历史消息，往上滚动加载更早的消息。
4. 以本人身份回复纯文本。
5. 新消息实时到达（目标几秒内，验收底线 1 分钟），弹 macOS 本地通知，点击通知跳到对应会话。
6. Dock 角标显示未读总数。

**不做**：发图片或文件、表情回应、撤回、话题群的楼中楼回复、搜索、通讯录、音视频、多账号、分发给别人用。

**消息展示**：文本和富文本（post）转成纯文本显示，其他类型一律显示占位符，例如 `[图片]`、`[文件] xxx.pdf`、`[卡片]`。

## 2. 架构

```
FeishuChat.app（SwiftUI，常驻）
 ├─ BackendSupervisor ── 启动并守护子进程：uv run feishu-lite-backend --port P（token 走环境变量）
 ├─ AppState ── HTTP 调用 + SSE 订阅 127.0.0.1:P
 ├─ 通知（UNUserNotificationCenter）、Dock 角标
 └─ 界面：登录（二维码）/ 会话列表 / 消息列表 + 输入框

feishu-lite-backend（Python，asyncio）
 ├─ LarkxSource ── 封装 larkx：扫码、feed、历史、发送、标已读、WebSocket 推送、保活
 ├─ Store ── SQLite 缓存（会话、消息、用户名）
 ├─ Service ── 推送入库再广播；断线重连后补拉；每 4 小时保活
 └─ API ── FastAPI：REST + SSE，Bearer token 鉴权，只绑定 127.0.0.1
```

**关键决定与理由**

- **后端由 App 拉起并守护，不用 launchd。** 通知必须由 App 发（点击通知才能跳到会话），App 不在跑的时候，后端单独在线也没有意义。一个进程生命周期更简单，也避开了 launchd 在这台机器上踩过的坑。App 用 `SMAppService.mainApp` 注册登录项，关掉窗口不退出。
- **协议层放在 Source 接口后面。** 逆向协议迟早会坏，到时只换 `LarkxSource`（最坏情况退化成官方 API 轮询），Store、API 和界面都不动。只抽这一层接口，其他地方不加抽象。
- **larkx 以固定 commit 的 git 依赖引入，不拷贝进仓库**（它没有 LICENSE）：`larkx @ git+https://github.com/cv-cat/LarkAgentX@2cb4f90fcfd5d7608800291ebb5e912ba6383901`。缺的能力在我们自己的代码里通过 `client.api()` 补。实在需要改 larkx 源码时，fork 到自己的 GitHub 再改依赖地址。
- **App 命名为 `FeishuChat`，bundle id 是 `com.reorx.FeishuChat`**，避开机器上已有的 Pake 应用 `Feishu Lite.app`（`com.reorx.feishu-lite`），防止 bundle id、通知授权和 WebKit 数据混在一起。
- **已读策略**：不自动标已读。用户在 App 里打开会话时，才调用 `mark_read` 同步到服务端，手机上的未读也会跟着清掉。
- **安全**：后端只监听 127.0.0.1，每个请求都要带 `Authorization: Bearer <token>`，token 由 App 每次启动时随机生成。这样可以防止浏览器页面跨站调用本地接口发消息，因为浏览器跨域不能带自定义头。凭证目录权限设为 700、文件设为 600。INFO 级别的日志里不打印消息正文。

## 3. 目录结构

```
~/Code/feishu-lite/
├── AGENTS.md
├── backend/              # uv 项目，包名 feishu_lite
│   ├── pyproject.toml    # script: feishu-lite-backend = feishu_lite.main:main
│   ├── src/feishu_lite/  # types.py source.py store.py service.py api.py render.py main.py
│   └── tests/            # 行为测试 + fixtures（脱敏的真实协议数据）
├── mac/                  # macos-app-bootstrap 生成的 SwiftUI 工程（FeishuChat + FeishuChatCore）
├── kb/
└── tmp/                  # 探路脚本、截图，已 gitignore
```

运行时数据放在 `~/Library/Application Support/FeishuChat/`：`larkx/` 存凭证（通过 `LARKX_HOME` 指定），`cache.db` 是本地缓存。

## 4. 后端设计

### 4.1 Source 接口（`source.py`）

| 方法 | larkx 实现 |
|---|---|
| `qr_login_start() -> qr_content` / `qr_login_poll() -> status` | `auth.QrLogin`（`wait` 是阻塞轮询，拆成一次调用只轮询一步，或者放到线程里跑） |
| `list_feed() -> list[Chat]` | **要在第 0 阶段摸清**：`client.api('feed.PullFeedCardsRequest', ...)`（cmd 1000），名称和头像再用 `chats.PullChatsByIdsRequest` 补齐 |
| `pull_history(chat_id, before_position, limit) -> list[Message]` | `client.pull_history(chat_id, positions)`，按 position 往前数 limit 个 |
| `send_text(chat_id, text) -> bool` | `client.send_msg` |
| `mark_read(chat_id, max_position)` | `client.mark_read` |
| `user_name(user_id, chat_id)` | `client.get_user_name`，结果缓存进 Store |
| `stream(on_message)` | `client.connect_websocket` |
| `keepalive()` | 自己实现，见 4.3 |

`FakeSource` 用于测试，实现同一个接口，由测试代码注入推送和历史数据。

### 4.2 larkx 集成注意事项（读源码确认过）

- `larkx.config` 在 **import 时**就读取 `LARKX_HOME`，并调用 `load_dotenv()`。必须在 import larkx 之前设置好这个环境变量。
- larkx 用同步的 `requests` 发请求。在 asyncio 里调用要包一层 `asyncio.to_thread`。`LarkClient.__init__` 会联网校验凭证，也要放到线程里。
- `connect_websocket` 会在 **larkx 自己的事件循环线程**里调用 `on_message`。回调里要用 `loop.call_soon_threadsafe` 或 `run_coroutine_threadsafe` 切回主循环。
- `connect_websocket` **不会自动重连**，断开就返回或抛异常。外面要自己套一层循环，退避间隔依次为 1、2、5、10、30 秒，每次重连后补拉消息（见 4.3）。
- 推送里自己在其他端发的消息也会回来（`from_id` 等于本人）。这类消息要入库，但不通知。
- 自动标已读只在 larkx 的 CLI 和 agent 分发器里生效，直接用 `LarkClient` 不会触发，但仍要确认一遍。
- 凭证失效时 larkx 抛 `AuthExpired`。此时状态切换为 `logged_out`，并广播出去。

### 4.3 保活与补拉

- **保活**：每 4 小时 `POST https://accounts.feishu.cn/accounts/csrf`（larkx 里的 `CSRF_URL`），把响应里的**所有** Set-Cookie（至少包括 `sl_session` 和 `swp_csrf_token`）合并进 `auth.cookies`，然后调用 `auth.save()`。larkx 自带的 `refresh_csrf()` 只存了 csrf，不够用。这个方案来自 feishu-user-plugin，第 0 阶段要实测。
- **补拉**：重连成功后，重新拉一次 feed。本地 `last_position` 落后于服务端 `lastMessagePosition` 的会话，把缺的消息拉回来入库。这些补拉到的消息只更新未读数，不逐条弹通知，避免断网恢复后通知刷屏。

### 4.4 HTTP API（`api.py`）

所有接口都需要 Bearer token。

| 接口 | 说明 |
|---|---|
| `GET /status` | `{state: logged_out/connecting/online/reconnecting, user: {id, name} 或 null, last_error}` |
| `POST /login/qr` | 返回 `{qr_content}`，App 自己渲染成二维码 |
| `GET /login/qr/status` | `{status: waiting/scanned/success/expired/failed}` |
| `POST /logout` | 删除凭证 |
| `GET /chats` | `[{id, name, type: p2p/group, unread, muted, last_message_preview, last_message_time}]`，按时间倒序 |
| `GET /chats/{id}/messages?before_position=&limit=30` | 按时间正序：`[{id, chat_id, position, sender_id, sender_name, is_self, create_time, type, text}]` |
| `POST /chats/{id}/messages` `{text}` | 发送。发出的消息几秒内会出现在会话里，不能重复 |
| `POST /chats/{id}/read` | 本地未读清零，同步调用 `mark_read` |
| `GET /events`（SSE） | 事件：`message.new {message, chat}`、`chat.updated {chat}`、`status {state}`；每 15 秒发一次心跳注释 |

数据模型用 pydantic 定义在 `types.py`。存储用标准库 `sqlite3`，不引入 ORM。

### 4.5 CLI

`feishu-lite-backend --port 18765`，从环境变量读 `FEISHU_LITE_TOKEN` 和 `FEISHU_LITE_HOME`。另加一个调试子命令 `feishu-lite-backend login`，在终端里打印二维码并扫码登录，第 0 阶段和排障时用。

## 5. App 设计（`mac/`）

- **初始化工程**：先读 `~/.claude/skills/macos-app-bootstrap/SKILL.md`，再直接跑脚本（这个 skill 禁止模型调用，不能用 Skill 工具）：
  `bash ~/.claude/skills/macos-app-bootstrap/scripts/scaffold.sh --name FeishuChat --bundle-prefix com.reorx --dir ~/Code/feishu-lite/mac`
  生成窗口应用，不加 `--menu-bar`。然后跑 `setup-signing.sh`，签名固定下来，通知授权才不会每次重建后丢失。写 SwiftUI 代码时参考 `swiftui-expert-skill`。
- **FeishuChatCore**（纯逻辑，写测试）：API 模型的 Codable 定义、SSE 行解析器、`NotificationPolicy`（决定一条消息要不要弹通知：本人发的不弹；免打扰会话不弹；App 在前台且正打开这个会话时不弹）。
- **FeishuChat**（App）：
  - `BackendSupervisor`：随机选一个空闲端口，生成 token，用 `Process` 启动 `uv run --project <BACKEND_DIR> feishu-lite-backend`。`BACKEND_DIR` 和 `uv` 的路径写在 xcconfig 里，通过 Info.plist 传给 App。轮询 `/status` 等后端就绪；子进程退出后按退避策略重启；App 退出时结束子进程。调试用环境变量 `FEISHU_LITE_BACKEND_URL` 和 `FEISHU_LITE_TOKEN` 直连一个已经在跑的后端。
  - `AppState`（`@Observable`）：订阅 SSE，断线自动重连；维护会话列表、当前会话和消息列表。
  - 界面：`NavigationSplitView`。
    - 左栏是会话列表：名称、预览、时间、未读徽标、免打扰图标。
    - 右栏是消息列表：发送者、时间、文本，自己发的消息靠右；滚到顶部时加载更早的消息。
    - 底部是输入框：回车发送，Shift+回车换行。
    - 未登录时显示登录页，用 CoreImage 的 `CIFilter.qrCodeGenerator` 把 `qr_content` 渲染成二维码。
    - 顶部显示连接状态。
  - 通知：标题是会话名，群聊的正文写成"发送者：内容"；点击通知激活 App 并选中对应会话。状态变成 `logged_out` 时，弹一条"飞书登录已失效，请重新扫码"。
  - Dock 角标显示非免打扰会话的未读总数。菜单里放一个"开机启动"开关（`SMAppService`）。

## 6. 测试策略（粗粒度 BDD）

按用户要求只写**行为级**测试，不给每个函数写单测。先写场景，再实现。

**后端**：`backend/tests/test_behaviors.py`，用 FakeSource 加 FastAPI TestClient 驱动 HTTP 和 SSE，覆盖以下场景：

1. 收到一条推送：会话未读数加 1，预览和时间更新，会话排到最前；SSE 发出 `message.new`。
2. 自己在其他端发的消息推回来：入库，未读数不变，事件里 `is_self=true`。
3. 打开一个没有缓存的会话：从 Source 拉历史，按时间正序返回；带 `before_position` 能继续往前翻。
4. 发送文本：Source 被调用；发出的消息出现在会话里，而且只出现一次。
5. 标已读：本地未读清零，Source 的 `mark_read` 收到正确的 `max_position`。
6. WebSocket 断开后重连：断线期间的消息被补拉入库，未读数正确，不逐条发 `message.new`。
7. 凭证失效：状态变成 `logged_out`，SSE 发出 `status`。
8. 不带 token 或 token 错误：返回 401。

另外用第 0 阶段抓到的**脱敏**真实数据做一组"消息内容转展示文本"的表驱动测试，覆盖文本、富文本、图片、文件、卡片、系统消息。

**Swift**：只测 Core 包里的三样：SSE 解析、模型解码、`NotificationPolicy`。界面不写测试，靠验收时截图检查。

## 7. 阶段

### 第 0 阶段：协议探路（约 1 天，风险最高，最先做）

脚本放在 `tmp/spike/`，不提交。**需要用户配合扫码，并提供一个测试会话**：让用户建一个只有自己的测试群，或者指定一个可以随便发消息的会话。**不要往真实工作群发测试消息。**

1. 建 `backend/` 的 uv 项目，`uv add` 加入 larkx 的 git 依赖；`LARKX_HOME` 指向 `tmp/spike/larkx-home`。
2. 扫码登录，二维码打印在终端里。**需要用户扫码，先告诉用户，再运行脚本。**
3. 监听 WebSocket 2 分钟，请用户用手机在测试会话里发几条不同类型的消息：文本、图片、富文本，再 @ 一下自己。记录推送字段。
4. 对测试会话调用 `pull_history`；向测试会话调用 `send_msg`，确认手机上收到了。
5. **摸清 feed 接口**：先在 `lark_all_pb2` 里找到 `PullFeedCardsRequest`/`Response` 的字段定义，用 `client.api()` 试着调用。调不通的话，就在浏览器里登录网页版飞书（用 agent-browser，需要用户扫码），抓 `x-command: 1000` 的请求体，用 larkx 的 proto 解码出参数。要确认的点：分页方式、排序、未读数字段、有没有免打扰标记、单聊怎么拿到对方名字。
6. **保活实测**：调用 csrf 接口，确认 Set-Cookie 里有新的 `sl_session`；解码 JWT，对比刷新前后的 exp。
7. 确认登录后，用户手机端和网页端都没有被踢下线；记下登录设备列表里显示的是什么。
8. 把发现写进 `kb/notes/2026-09-29-protocol-spike.md`，**脱敏**后的样本数据放进 `backend/tests/fixtures/`（替换人名、消息内容和各种 id）。

**完成标准**：登录、推送、历史、发送、feed 五项都有能跑通的脚本。
**降级方案**：如果 feed 花了 1 天还没摸清，就用"本地缓存 + 推送 + `get_chat_info`"拼出会话列表（只能显示登录之后有过消息的会话），记到 known-issues，继续往下做。

### 第 1 阶段：后端（约 1.5 天）

1. 先写第 6 节的行为测试（此时全部失败），再按 types → store → source → service → api → main 的顺序实现，直到测试全部通过。
2. 用真实账号手动检查：启动后端，用 curl 调 `/status`、`/chats`、`/chats/{id}/messages`，订阅 `/events` 后在手机上发一条消息，看事件有没有推过来。
3. 提交代码。

### 第 2 阶段：SwiftUI App（约 2 天）

1. 按第 5 节初始化工程，签名配好后 `make test`、`make build`、`make run` 都能跑通。
2. Core 包：先写测试，再实现模型、SSE 解析和通知策略。
3. App：BackendSupervisor → 登录页 → 会话列表 → 消息页和发送 → 通知和 Dock 角标 → 开机启动。
4. 每完成一块就用真实账号跑一遍，截图存到 `tmp/2026-09-29-feishu-chat-mvp/`（日期按实际完成那天）。
5. 提交代码。

### 第 3 阶段：验收与收尾（约 0.5 天）

逐项跑第 8 节的清单，截图存档。然后：

- 把没通过的项、有意为之的简化实现写进 `kb/known-issues.md`。
- 把"连续运行 24 小时后仍在线"这项检查写进 `kb/next-up.md`。
- 写 session 总结和 AGENTS.md（用 `/kb ss`）。
- 提交代码。
- 用过 agent-browser 的话，跑一遍 `mac-dev-cleanup --only browser`。

## 8. 验收清单

1. 全新启动 App，扫码登录后，会话列表和手机飞书的前 20 个会话一致：名称、顺序、未读数都对得上。
2. 在手机上让测试会话收到一条单聊消息：Mac 在 5 秒内弹出通知，点击后打开对应会话。
3. 免打扰群有新消息：不弹通知，但未读数增加。
4. 打开一个会话：历史消息能加载，往上滚能继续加载；手机上这个会话的未读同时清掉。
5. 在 App 里回复：手机上能看到，App 里这条消息只出现一次。
6. 断网 2 分钟，期间在手机上发消息；恢复网络后，这些消息出现在 App 里，未读数正确，没有通知刷屏。
7. 关闭窗口，App 仍在运行，新消息照样弹通知；退出 App 后，后端进程也跟着退出（检查 `pgrep -f feishu-lite-backend`）。
8. 手动删掉凭证里的 `session`：App 进入登录页，并弹出"需要重新扫码"的通知。
9. 连续运行超过 24 小时仍然在线（写进 next-up，择日检查）。

## 9. 风险与已知限制（开发完成后写进 `kb/known-issues.md`）

- **协议随时可能失效**：larkx 里的版本号（sdk 7.72.8、web 3.9.32）是写死的，基本只有一个人在维护。出问题时先看上游有没有新 commit。
- **违反飞书使用条款**。larkx 没有 LICENSE，只能个人使用。
- 凭证以明文 JSON 存储，靠文件权限保护。以后可以挪进钥匙串。
- 图片、文件、卡片只显示占位符；话题群里只能在主会话回复。
- 保活方案靠借鉴得来，未经长期验证。

## 10. 需要用户配合的时刻

- 第 0 阶段的第 2 步和第 5 步：扫码登录（手机飞书）。
- 第 0 阶段的第 3 步和第 8 节的验收：在测试会话里发消息，确认手机上的状态。
- 提供测试会话：不要往真实工作群发测试消息。
