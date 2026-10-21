---
created: 2026-10-21
tags:
  - plan
  - mock-data
  - testing
  - screenshots
  - readme
---

# 用 JSON 模拟数据启动 App，并给 README 配截图

## PRD

### 背景

FeishuLite 的界面只能连真实飞书账号和真实邮箱才有内容。截图、做演示、做官网时，真实数据里有同事的名字和工作内容，不能拿出去用。

之前做界面验收时，执行者每次都要自己复制一份 App 源码、打补丁、手写一个假后端（`tmp/` 下的 U1、R8b 工具），既重复劳动，也不入库，下一次用不上。

### 目标

1. 开发者用一个环境变量启动 App，App 就显示一套事先写好的 JSON 模拟数据：聊天会话和消息、邮件列表和正文。界面上的行为（打开会话、翻页、读邮件、发消息）照常可用，但不连飞书、不连邮箱，也不碰真实账号的任何数据。
2. 用这套机制做一套像样的展示数据，截出能代表 App 的图，放到 GitHub README 首页。

### 功能与交互

**模拟数据集**

- 一个数据集是一个目录，里面分别放聊天和邮件的 JSON 文件，以及聊天图片消息用到的图片文件。
- 仓库里提交一套标准数据集 `mock-data/showcase/`，用于截图、演示和以后的自动验收。环境变量可以指向任意目录，所以个人临时用的变体数据可以放在 `tmp/` 下，不入库。
- 数据里的时间写成"今天 09:30""昨天 18:05""3 天前 14:00"这种相对日期加固定钟点。这样任何一天启动，截图都显得是最近的数据，钟点也每次一样。
- 数据集可以只有聊天或只有邮件。缺了邮件文件时，Email 模块显示"未配置"的界面。缺聊天文件时怎么表现由实现定，但一定不能去连真实飞书。

**启动方式**

- Debug 版 App 设了模拟数据环境变量后启动，就进入模拟模式。提供一个 make 命令，一步完成构建并用标准数据集启动。
- 模拟模式下，聊天显示已登录、在线；邮箱显示已配置、在线。会话列表、未读数、免打扰、会话里的文本、多行文本、图片、视频会议邀请、自己发的消息都按数据显示。邮件列表、已读未读、附件信息、HTML 和纯文本正文都按数据显示。
- 在模拟模式里操作：打开会话会清未读，发文字会出现在会话里，打开邮件会变成已读。这些变化只保存在这次运行里，退出后再启动，又回到 JSON 里的初始状态，JSON 文件本身不被改写。
- 模拟模式不弹系统通知，不改开机启动设置，不读写钥匙串，不读写真实的聊天/邮件缓存和登录凭证，不改正式 App 的偏好设置（模块选择、隐藏会话等）。用户日常用的 FeishuLite 正在运行时，再启动一个模拟模式的实例，日常那个不受影响。
- 模拟数据目录不存在或 JSON 写错时，App 给出明确的错误（后端日志写清是哪个文件哪一项），不会退回去连真实账号。

**README 截图**

- README 首页加两张截图：一张展示聊天（Messages），一张展示邮件（Email）。
- 每张截图有浅色和深色两版，GitHub 按访客的系统主题自动显示对应的一版。
- 截图里的人名、公司、邮件地址、消息内容全部虚构，不出现真实同事、真实公司或真实品牌。邮件地址用 `example.com` 这类保留域名。图片消息里的图片是自己生成的，不用来源不明的照片。

### 不做的事

- 不模拟异常状态：断网、登录过期、扫码登录页、邮箱密码错误、加载失败等。以后需要时在同一机制上扩展。
- 不模拟"运行中有新消息/新邮件到达"和系统通知。
- Release 版不提供模拟模式。
- 不做官网，只产出截图素材（候选截图留在 `tmp/` 下备用）。
- 不改 App 现有界面。截图时发现的界面问题记下来交给协调者，不在本次顺手改。

### 验收标准

1. 用 make 命令或一条 `open --env` 命令，Debug 版 App 启动后直接显示 `mock-data/showcase/` 里的会话和邮件，没有扫码页，邮箱不要求输入密码。
2. 打开会话后未读清零、发一条文字能看到、打开未读邮件后变已读；退出再启动，全部回到初始状态，JSON 文件没有变化。
3. 模拟模式运行前后：日常运行的 FeishuLite 进程还在；真实数据目录里的缓存和凭证没有被模拟实例打开过；正式偏好域里 App 自己的键没变；钥匙串没有被访问；没有弹出系统通知。
4. 环境变量指向不存在的目录或格式错误的 JSON，App 显示后端启动失败，日志说明原因，不去连真实账号。
5. `AGENTS.md` 说明了这个机制，并指出界面调整的测试和自动化验收应优先走这条路径；`kb/docs/` 里有一份说明数据格式和用法的文档。
6. README 首页显示一张聊天截图、一张邮件截图，在 GitHub 浅色和深色主题下分别显示对应版本，内容都是虚构的。

## Tech Design

### 现状

- App 由 `mac/FeishuLite/Services/BackendSupervisor.swift` 拉起后端子进程（Debug 用 `uv run --project <backend> feishu-lite-backend --port P`），子进程环境继承 App 的环境，另外设 `FEISHU_LITE_TOKEN`、`FEISHU_LITE_PARENT_PID`、`FEISHU_LITE_HOME`。配置读取在 `Services/BackendConfig.swift`，已有 `FEISHU_LITE_HOME` 和外部后端（`FEISHU_LITE_BACKEND_URL` + `FEISHU_LITE_TOKEN`）两个开关。
- `App/AppDelegate.swift` 创建 `AppState(supervisor:notifications:windows:)`。`Model/AppState.swift` 的构造函数已经能注入 `preferences: UserDefaults` 和 `credentials: MailCredentialStore`。`MailState` 在 `externalBackend == true` 时不读写钥匙串（`MailState.swift` 304、316、337 行附近）。
- 后端入口 `backend/src/feishu_lite/main.py`：`prepare_home()` 决定数据目录并设置 `LARKX_HOME`，`run_server()` 组装 `Service(LarkxSource(), Store(home / 'cache.db'))` 和 `create_app(service, token, mail_path=home / 'mail.db')`。
- 聊天：`service.py` 的 `Service` 只通过 `source.py` 的 `Source` 协议访问飞书（restore、list_feed、get_chat、pull_history、send_text、fetch_image、mark_read、user_names、stream、keepalive、qr 登录）。`backend/tests/fakes.py` 的 `FakeSource` 是一个内存实现，可以参考。
- 会议邀请消息 `type == 'video_chat'`，文本格式由 `render.py` 的 `_meeting_text` 生成（标题行、`会议号：xxx xxx xxx`、`入会入口：https://vc.feishu.cn/w/<9 位数字>`），App 的 Core 解析这段文本。图片消息 `type == 'image'`，`Service.get_image` 调 `source.fetch_image(message)` 取字节并校验格式。
- 邮件：`mail/service.py` 的 `MailService(store, adapter_factory=ImapAdapter, ...)`，IMAP 访问全部经 `adapter_factory` 创建的适配器。`backend/tests/mail/fake_imap.py` 的 `FakeImap` 是契约级假实现，HTML 正文经 `mail/html.py` 的 `render_body` 净化。账号存在 `MailStore`，密码只在内存，通过 `configure` / `inject_credential` 进入。
- 之前的验收用 `tmp/2026-10-17-email-reader-finish/u1/tools/fixture.py`（线协议级假后端，676 行）和打了 5 个钩子的源码副本，没有入库。

### 方案

在后端加模拟模式：`feishu-lite-backend --mock-data <dir>`。模拟模式用 JSON 驱动的 `MockSource` 替换 `LarkxSource`，用 JSON 驱动的假 IMAP 适配器替换 `ImapAdapter`，`Service`、`MailService`、`Store`、`MailStore`、HTTP/SSE 接口都用真的。App 在 Debug 下读环境变量 `FEISHU_LITE_MOCK_DATA`，把它传给后端，并在本进程里换上隔离的偏好、空的凭证存储和静默的通知。

关键决策：

| 决策 | 理由 | 否决的备选 |
|---|---|---|
| 在后端的数据源/适配器这一层注入，而不是写一个线协议级假服务 | 截图和测试走真实的缓存、排序、预览、会议文本、HTML 净化、分页、已读代码，接口两侧也不会和真后端漂移 | 照 U1 `fixture.py` 写假 FastAPI：要逐个复刻接口，后端一改就过时；能模拟任意异常状态，但这次不需要 |
| 不在 App 里直接读 JSON | App 的数据全部来自后端接口和 SSE，绕过它们截出来的图和真实运行不一样，还要在 Swift 里重写一遍合并逻辑 | — |
| 每次启动用一个新建的临时数据目录，退出时删除 | 每次都从 JSON 的初始状态开始，截图可复现；物理上不可能碰到真实缓存和凭证 | 复用 `FEISHU_LITE_HOME`：上次运行的状态会残留 |
| 模拟模式不 import larkx | 不可能误连飞书，也不依赖 larkx 的环境变量 | — |
| 邮箱在模拟模式里由后端自动配置账号并注入一个假密码 | App 不需要碰钥匙串，邮箱直接 online；首次同步按"导入历史"处理，不产生待提醒批次 | 让 App 走配置页输入：截图前多一步，还会写钥匙串 |
| App 只在 Debug 下认这个环境变量 | 用途是开发、截图和验收；Release 用户不会误触 | — |
| 数据集入库到 `mock-data/<场景>/`，标准场景叫 `showcase` | 新 clone、worktree 和以后的 agent 都能直接用；按场景分目录，以后加异常场景不用改格式（用户 2026-10-21 确认入库） | 放 `tmp/`：被 gitignore，别人拿不到 |
| 相对时间写成"相对天数 + 固定钟点" | 任何一天截图都像最近的数据，钟点每次一样，像素对比也稳定 | 相对秒数：钟点每次变；绝对时间：过几天就显得陈旧 |

### 数据变动

新增入库目录 `mock-data/showcase/`：

```
mock-data/showcase/
  messages.json   # 本人、联系人、会话及每个会话的消息
  emails.json     # 邮箱地址、文件夹、邮件
  images/         # messages.json 里图片消息引用的图片
```

具体字段由 T1 定，写进 `kb/docs/mock-data.md`。必须能表达：

- 聊天：本人；联系人 id 和名字；会话的 id、名字、单聊/群聊、免打扰、未读数；消息的发送者（包括本人）、时间、类型（文本、富文本、图片、视频会议、系统消息至少这几种）和内容。会议邀请用结构化字段（主题、9 位会议号），由模拟数据源按 `_meeting_text` 的格式生成文本，不让写数据的人手拼。图片消息引用 `images/` 下的文件。
- 邮件：邮箱地址；文件夹列表（收件箱之外也可以列出其他文件夹）；每封邮件的发件人、收件人、抄送、主题、时间、已读/未读、HTML 或纯文本正文、附件信息（文件名、类型、大小）。
- 时间：相对天数加钟点，比如 `{"day": 0, "time": "09:30"}` 或等价的字符串写法，具体由 T1 定；也允许绝对时间。

后端 SQLite 表结构、HTTP 接口、App 的模型都不变。

### 逻辑变动

后端（`backend/src/feishu_lite/`）：

- 新增模拟模块（如 `mock/` 包或 `mock.py`）：
  - 读取并校验数据集，用 pydantic 模型描述 JSON。错误信息指出文件和条目。
  - `MockSource`：实现 `Source` 协议。`restore` 返回本人；`list_feed` / `get_chat` / `pull_history` 从内存数据返回；`send_text` 生成一条本人消息并加进内存；`mark_read` 只改内存；`fetch_image` 读 `images/` 下的文件；`stream` 调 `on_connected` 后一直挂起直到被取消；`keepalive` 什么都不做；qr 登录相关方法不联网。
  - 模拟 IMAP 适配器：满足 `MailService` 对适配器的契约（参考 `tests/mail/fake_imap.py`），从内存数据返回文件夹、摘要、正文，支持设置已读。
- `main.py`：加 `--mock-data DIR`（也可以接受同名环境变量）。模拟模式下建临时数据目录，不调用 `prepare_home()` 里设置 `LARKX_HOME` 的那部分、不 import larkx，组装 `Service(MockSource(...), Store(tmp / 'cache.db'))`，邮件用模拟适配器，并在启动时为数据集里的邮箱地址配置账号、注入假密码。退出时删除临时目录。父进程检查等现有机制照旧。
- 不改 `api.py`、`types.py`、`mail/types.py` 的接口。确实需要给 `create_app` 加注入点时，只加可选参数，不改现有调用的行为。

App（`mac/FeishuLite/`）：

- `BackendConfig`：Debug 下读 `FEISHU_LITE_MOCK_DATA`，相对路径按仓库根目录解析（Debug 的 `backendDir` 的上一级），得到 `mockDataDir`。
- `BackendSupervisor`：`mockDataDir` 有值时给后端加 `--mock-data <dir>`，不传 `FEISHU_LITE_HOME`。
- `AppDelegate`：模拟模式下给 `AppState` 注入独立的偏好（如 `UserDefaults(suiteName: "com.reorx.FeishuLite.mock")`，启动时清空）、空的凭证存储、静默的通知中心，不碰 `LoginItem`。`MailState` 的钥匙串逻辑按"凭证由后端管理"处理，可以复用或推广 `externalBackend` 这一判断。
- SwiftUI 自己保存的窗口尺寸等键如果没法隔离，在文档里写明。

工具：

- `mac/Makefile` 加 `run-mock`（构建后用 `mock-data/showcase` 启动）。不能像 `make run` 那样结束所有 FeishuLite 进程，只能结束它自己上次启动的模拟实例。

文档：

- 新增 `kb/docs/mock-data.md`：给开发者和 agent 看，说明模拟模式是什么、怎么启动、数据格式、隔离保证、怎么加一个新场景，以及推荐的用途（界面调整后的截图对比、自动化验收）。
- `mac/AGENTS.md` 的调试环境变量表和根 `AGENTS.md` 的说明由协调者在签收后更新。

### 实施步骤

- [x] T1 后端：先写行为测试（数据集解析与校验、相对时间、MockSource 各方法、模拟邮箱的列表/正文/已读、启动时自动配置邮箱且不产生待提醒、错误数据报错），再实现模拟模块和 `--mock-data`
- [x] T1 App：先写 `BackendConfig` 解析和模拟模式装配的测试，再实现环境变量、参数传递、偏好/凭证/通知隔离
- [x] T1 提交最小的 `mock-data/showcase/`，覆盖所有支持的消息和邮件类型；加 `make run-mock`
- [x] T1 写 `kb/docs/mock-data.md`
- [x] T1 实机验证：隔离构建，模拟模式启动，两个模块都有数据，验收标准 1–4 逐条留证据
- [x] T2 把 `mock-data/showcase/` 扩充成像样的展示数据
- [x] T2 截候选图（深浅色），挑出聊天和邮件各一张，提交到 `mac/Artwork/screenshots/`
- [x] T2 README 加截图区，用 `<picture>` 按主题切换
- [x] 协调者：更新根 `AGENTS.md`、`mac/AGENTS.md`

### 测试与验证

| 验收标准 | 怎么验 |
|---|---|
| 1 直接显示模拟数据 | 隔离构建的 Debug App 用 `open -n --env FEISHU_LITE_MOCK_DATA=...` 启动，截 Messages 和 Email 的窗口图 |
| 2 操作只在本次运行内有效 | 后端行为测试覆盖 send/mark_read/read；实机打开会话、发一条文字、打开未读邮件后截图，退出重启再截图；对比 JSON 文件的 hash |
| 3 隔离 | 单测：模拟模式装配用的是独立偏好、空凭证、静默通知。实机：日常 FeishuLite 进程还在；`lsof` 看模拟后端只打开临时目录；对比正式偏好域里 App 自己的键；没有通知横幅 |
| 4 错误数据 | 后端测试覆盖；实机用不存在的目录启动一次，截图并摘日志 |
| 5 文档 | 检查 `kb/docs/mock-data.md` 和两份 AGENTS.md |
| 6 README | 在 GitHub 或本地 Markdown 预览确认 `<picture>` 结构；四个 PNG 都存在、尺寸一致、内容虚构 |

后端测试：`cd backend && uv run pytest`。App：`cd mac && make test`，构建用 `make build DERIVED_DATA=<tmp 下的目录>`，避免覆盖用户正在运行的 Debug App。

### 风险与待定

- `MailService` 首次打开邮箱时是否把已有未读当历史导入、不产生待提醒批次，要在测试里钉住。如果会产生，模拟模式要在启动时确认掉，或者通知中心静默后在文档里说明。
- 同一个 bundle id 的两个实例同时运行时，SwiftUI 的窗口状态、通知授权是共享的。模拟实例只要不写 App 自己的偏好键、不发通知，就不影响日常实例；SwiftUI 自动保存的窗口尺寸可能写进正式偏好域，T1 实测后在文档里说明。
- 富文本消息（`post`）在 App 里怎么显示取决于后端渲染出的文本，模拟数据直接给最终文本即可，不模拟原始协议结构。
