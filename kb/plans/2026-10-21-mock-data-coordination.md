---
created: 2026-10-21
tags:
  - coordination
  - mock-data
  - screenshots
---

# 模拟数据与 README 截图：协调记录

本文由协调者（主会话 Claude Code）编写，既是各执行者共用的 brief，也是协调记录。协调者定的部分，执行者可以在自己的总结里提出反对并写明理由。

要做什么、为什么、怎么做，以 [plan](2026-10-21-mock-data-plan.md) 为准，本文不重复，只写分工、约束和状态。

## 决定表

| 问题 | 决定 | 谁定的 |
|---|---|---|
| 谁执行 | 全部交给 Astra（Codex，`gpt-6-astra`，effort medium），包括截图和 README | 用户 |
| 数据放哪 | 入库到 `mock-data/<场景>/`，标准场景 `showcase`；环境变量可指向任意目录，临时变体放 `tmp/` | 用户，2026-10-21 |
| README 截图外观 | 聊天、邮件各一张，每张深浅两版，`<picture>` + `prefers-color-scheme` 自动切换 | 用户，2026-10-21 |
| 注入层 | 后端数据源/IMAP 适配器层（`MockSource` + 模拟适配器），不写线协议假服务，不在 App 里读 JSON。理由见 plan「方案」 | 协调者 |
| 只在 Debug 认环境变量 | App 只在 Debug 读 `FEISHU_LITE_MOCK_DATA`；后端的 `--mock-data` 参数不限 | 协调者 |
| 拆分 | T1 机制（后端 + App + 最小数据集 + 文档）→ T2 展示数据 + 截图 + README。T2 依赖 T1 的数据格式和启动方式，串行 | 协调者 |
| T1 的测试和数据集的关系 | 后端和 App 的测试用自己的测试数据；对 `mock-data/showcase/` 只做"能加载、校验通过"的检查，不断言具体内容。原因：T2 要改写 showcase 的内容，测试不能因此变红 | 协调者 |
| 截图存放 | 选中的 4 个 PNG 放 `mac/Artwork/screenshots/`（和 README 已经引用的 App 图标放一起）；候选图留在 `tmp/2026-10-21-mock-data/t2/` 给以后做官网用 | 协调者 |
| 会议邀请显示成普通气泡 | T1 的缺陷：`mock.py` 生成的会议文本缺 `[视频会议] ` 前缀，App 的 `MeetingInvitation` 解析失败、退回原文。追加 T1b，由 `mockdata-t1` 修：render 和 mock 共用同一个会议文本函数。协调者审 T1 截图时漏看了 | 用户发现并同意修法，2026-10-21 |
| 深色截图 | `-AppleInterfaceStyle` 启动参数对本 App 无效。T2 加一个 Debug 专用的外观开关（环境变量，启动时设 `NSApp.appearance`），不改系统外观。这是 T2 范围内唯一的代码改动 | 协调者 |
| 截图时抢焦点 | 用户同意截图时把模拟实例短暂切到前台，以截到激活状态的窗口 | 用户，2026-10-21 |
| T2 中断 | 用户手误，按原计划继续 | 用户，2026-10-21 |
| 共享文件 | 根 `AGENTS.md`、`mac/AGENTS.md`、`kb/known-issues.md`、`kb/next-up.md`、plan 的勾选、本文，都由协调者在签收后更新。`kb/docs/mock-data.md` 归 T1，T2 只在格式说明或外观开关需要补充时改它，T1b 不改它。README 归 T2，只加截图区 | 协调者 |

## 必读

所有执行者先读：

1. 根 `AGENTS.md` 和 `mac/AGENTS.md`。
2. [plan](2026-10-21-mock-data-plan.md) 全文。
3. 本文全文。
4. 要运行 App 的任务：`~/.claude/docs/DESKTOP_APP_TESTING.md`。

各任务额外的必读写在各自一节。

## 任务

| 任务 | agent 名 | 类型 | 依赖 | 验证方式 |
|---|---|---|---|---|
| T1 模拟数据机制 | `mockdata-t1` | Astra | 无 | 后端和 App 测试先红后绿；隔离构建的 App 实机启动，逐条验收 plan 的标准 1–4 |
| T1b 会议邀请格式修复 | `mockdata-t1b`（`mockdata-t1` context 超 40%，换新 agent） | Astra | 无（和 T2 并行，文件不重叠） | 测试先红后绿；实机截一张会议卡片 |
| T2 展示数据、截图、README | `mockdata-t2` | Astra | T1 签收 | 截图由协调者审；README 的 `<picture>` 结构和图片路径可用 |
| T2b 截图、入库、README（接续 T2） | `mockdata-t2b` | Astra | T1b 签收 | 同 T2 |

### T1 模拟数据机制

额外必读：`backend/src/feishu_lite/main.py`、`service.py`、`source.py`、`mail/service.py`；`backend/tests/fakes.py`、`backend/tests/mail/fake_imap.py`；`mac/FeishuLite/Services/BackendConfig.swift`、`BackendSupervisor.swift`、`App/AppDelegate.swift`、`Model/AppState.swift`、`Model/MailState.swift`。

范围：plan「Tech Design」里后端、App、工具、文档四部分，加最小数据集 `mock-data/showcase/`。

- 最小数据集要覆盖所有支持的类型：单聊、群聊、免打扰、有未读；文本、多行文本、富文本、图片、视频会议邀请、系统消息、本人发的消息；邮件里未读、已读、HTML 正文、纯文本正文、带附件、抄送多人；收件箱以外至少再列一个文件夹。内容虚构即可，不用好看，T2 会重写。
- 数据格式由你定，写进 `kb/docs/mock-data.md`。格式要让 T2 只改 JSON 和图片就能做出展示数据，不用改代码。

不做：

- 不模拟异常状态和运行中的新消息到达（plan「不做的事」）。
- 不改 App 现有界面，不改 HTTP 接口和 wire 模型。
- 不做截图挑选和 README。

完成标准：

- 后端：先写行为测试再实现，`cd backend && uv run pytest` 全部通过，记录新增和总数。测试覆盖 plan「实施步骤」T1 后端一行列出的行为。
- App：`cd mac && make test` 全部通过，记录数量；`make build DERIVED_DATA=<你的证据目录>/DerivedData` 通过。
- 实机：用隔离构建的 App，`open -n --env FEISHU_LITE_MOCK_DATA=<仓库>/mock-data/showcase` 启动，按 plan「测试与验证」的表逐条留证据（验收标准 1–4）。截图至少包括 Messages 打开一个会话、Email 打开一封 HTML 邮件，浅色即可。
- `make run-mock` 能用（用 `DERIVED_DATA` 指向你的目录来验证），且不会结束非模拟的 FeishuLite 进程。
- `kb/docs/mock-data.md` 写好：读者是以后要做界面测试或自动化验收的开发者和 agent，说明用途、启动、数据格式、隔离保证和已知的隔离缺口、怎么加新场景、怎么在脚本里截图。按 kb 技能的 docs 写法，写现状不写经过。
- 总结写到 `kb/sessions/2026-10-21-mock-data-t1.md`，证据放 `tmp/2026-10-21-mock-data/t1/`。总结的「交给协调者」里写好要加进根 `AGENTS.md` 和 `mac/AGENTS.md`（调试环境变量表、命令列表）的文字。

### T1b 会议邀请格式修复

问题：`backend/src/feishu_lite/mock.py` 第 47 行拼会议文本时，第一行只有主题，缺 `render.py` 的 `_meeting_text` 生成的 `[视频会议] ` 前缀。App 的 `MeetingInvitation`（`mac/FeishuLiteCore/Sources/FeishuLiteCore/MeetingInvitation.swift`）要求这个前缀，解析失败就退回显示原文，所以模拟模式里会议邀请不是卡片。真实使用不受影响。

范围：

- 先写失败测试：模拟出的 `video_chat` 消息文本，和真实渲染对同一主题、会议号的输出一字不差。
- 把 `_meeting_text` 里由主题和会议号拼文本的部分抽成一个公共函数，`render.py` 和 `mock.py` 都调它。真实渲染的输出不能变，现有 render 和会议缓存测试保持通过。
- 顺带审一遍 `mock.py` 里其他自己生成的文本或字段，有没有偏离真实后端的契约。有就修，修不了的写进「交给协调者」。

不做：不改 `mock-data/showcase/`（T2 正在改，工作区里有它没提交的改动）；不改 `kb/docs/mock-data.md`、App 和 `api.py`。

完成标准：

- `cd backend && uv run pytest` 全部通过，记录总数。
- 实机：用你自己的场景副本（放在 `tmp/2026-10-21-mock-data/t1b/` 下，不要依赖 showcase 的工作区状态）和已有的隔离构建启动，截一张会议邀请显示成卡片的窗口图。只改了后端，Debug App 跑的是源码后端，不用重新构建 App。不需要激活窗口，不要抢焦点。
- 在 `kb/sessions/2026-10-21-mock-data-t1.md` 末尾加一节「T1b 会议邀请格式」，证据放 `tmp/2026-10-21-mock-data/t1b/`。只提交自己的文件。

### T2 展示数据、截图、README

T1 已在 `421c7a3` + `2deb879` 签收，本节按 T1 的实际数据格式和启动方式定稿。模拟实例的偏好只在内存里，退出后后端临时目录自动删除；你只需要按 pid 结束自己启动的实例。

额外必读：`kb/docs/mock-data.md`（数据格式、启动、截图方法）、`kb/sessions/2026-10-21-mock-data-t1.md`、`backend/src/feishu_lite/mock.py` 里的数据模型、`README.md`、现有的 `mock-data/showcase/`。T1 的截图在 `tmp/2026-10-21-mock-data/t1/`，可以先看一眼现在的样子。

范围：

1. **重写 `mock-data/showcase/` 为展示数据。** 只改 JSON 和图片，不改代码。数据格式不够用时，停下来写进「交给协调者」，不要自己改 `mock.py`。
   - 一个虚构公司里的一个产品团队，中文内容，读起来像真实的工作沟通，但不涉及敏感话题。人名、公司、项目名全部虚构，不出现真实品牌、真实同事。邮件地址用 `example.com` 这类保留域名。
   - 聊天：会话列表要有十个左右，单聊和群聊都有，一两个免打扰，未读数有多有少，最后一条消息的时间分布在今天、昨天和这周早些时候。要截图的那个会话（主角会话）要多人参与，消息多到能填满详情区（T1 的截图里会话太短，顶部空了一大块），并且包含：多行文本、本人发的消息、一张图片、一个视频会议邀请，可以再加一条富文本。
   - 图片自己生成（比如用 PIL 画一张产品数据图表或界面草图），要好看，不要灰色占位块；不用网上下载的、来源不明的图。
   - 邮件：收件箱十五封左右，发件人各不相同，几封未读，几封带附件；文件夹列出收件箱、已发送、草稿、归档、垃圾邮件这类常见项。要截图的那封（主角邮件）是 HTML，不依赖远程图片也好看（标题层级、表格、列表），比如一份周报或版本发布说明；再有一封纯文本邮件。
2. **截候选图。** 用 `make -C mac run-mock DERIVED_DATA=<你的证据目录>/DerivedData`（或已构建的 App 加 `open -n --env`）启动。
   - 四张成品图用同一个窗口尺寸，宽度要能同时放下侧栏、列表和详情，正文清晰可读。尺寸由你定，写进总结。
   - 深浅两版：只改模拟实例自己的外观，**不要改系统外观**，那会影响用户整个桌面。先试 `open -n --env ... <App> --args -AppleInterfaceStyle Dark`（浅色用 `Light`），确认两种都生效。都不生效时停下来报告协调者。
   - 至少截这几个候选，深浅各一版：Messages 主角会话；Email 主角 HTML 邮件；Email 纯文本邮件；另外一两个你觉得能代表 App 的画面（比如图片预览、侧栏收起）。放在 `tmp/2026-10-21-mock-data/t2/candidates/`，配一个索引文件说明每张图是什么。这些图以后做官网会用到。
   - 窗口阴影要不要保留由你定，四张成品保持一致。
3. **挑选并入库。** 从候选里选 Messages、Email 各一张，深浅两版共四个 PNG，放到 `mac/Artwork/screenshots/`，文件名形如 `messages-light.png`、`messages-dark.png`、`email-light.png`、`email-dark.png`。单个文件尽量不超过 1 MB：可以用 `sips` 缩小尺寸，或者用本机已经装好的 PNG 压缩工具，不要另装新工具。
4. **README。** 在标题和一句话介绍之后、「功能」之前加截图区。每张图用：

   ```html
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="mac/Artwork/screenshots/messages-dark.png">
     <img src="mac/Artwork/screenshots/messages-light.png" alt="……">
   </picture>
   ```

   两张图横排还是竖排、要不要配一行说明，由你定。README 其他部分不改。

不做：

- 不改 App 界面和任何代码。截图时发现的界面问题（比如布局、截断、颜色），截图存证，写进「交给协调者」。
- 不做官网。

完成标准：

- `mock-data/showcase/` 能加载：`cd backend && uv run pytest` 全部通过（其中有 showcase 的加载检查），记录总数。
- 候选图和索引都在 `tmp/2026-10-21-mock-data/t2/candidates/`，深浅两版都有。
- 四个 PNG 在 `mac/Artwork/screenshots/`，尺寸一致，记录每个文件的像素尺寸和大小。
- README 的截图区在本地 Markdown 预览里显示正常（GitHub 的深浅切换没法在本地验证，确认 HTML 结构和路径正确即可）。
- 逐张检查截图内容，不出现真实人名、公司、邮件地址，也没有截到用户的 App 或桌面上的其他内容。
- 总结 `kb/sessions/2026-10-21-mock-data-t2.md`，写清：选了哪两张、为什么；窗口尺寸和外观切换的做法；数据集的构成；截图里发现的界面问题。

#### T2 追加（2026-10-21，T2 中断后恢复时）

- **先清理**：结束你自己留下的模拟实例（pid 81661）和它的后端，按 pid 结束，确认没有别的模拟实例在跑。已有的候选图里，「深色」版其实是浅色，窗口也都是非激活外观，需要重截。
- **外观开关**：`-AppleInterfaceStyle` 启动参数对本 App 无效。在 Debug 里加一个环境变量（建议 `FEISHU_LITE_APPEARANCE=light|dark`，不限于模拟模式），App 启动时据此设置 `NSApp.appearance`，不设就跟随系统。Release 不认这个变量。先写测试（解析和装配），再实现；用法写进 `kb/docs/mock-data.md` 的截图部分；要加进 `mac/AGENTS.md` 调试变量表的文字写进「交给协调者」。这是 T2 唯一允许的代码改动。
- **激活截图**：用户同意截图时把模拟实例短暂切到前台。用户日常的 FeishuLite 和模拟实例是同一个 bundle id，必须按 pid 激活（比如 System Events 里按 `unix id` 找进程设 `frontmost`，或 `NSRunningApplication(processIdentifier:)`），不要按 App 名字激活。截图前确认窗口是激活外观（红绿灯有颜色）。
- **会议卡片**：T1b 正在修会议邀请的显示。Messages 主角会话的成品图要等协调者通知 T1b 已修好再截。没收到通知时，先做外观开关和 Email 的截图；能做的都做完了还没收到，就停下回复协调者。

#### T2b 接续（2026-10-21）

`mockdata-t2` 在 context 45% 时停下。展示数据（`16c5d9c`）和外观开关（`a2812bc`）协调者已审过，不用重做。T1b 已在 `8be3af8` 签收，会议邀请现在显示成卡片，Messages 主角会话可以直接截。

做 T2 剩下的部分：先读 `kb/sessions/2026-10-21-mock-data-t2.md` 末尾的「交给协调者：接续清单」，照它做截图、挑选入库、README、核对和总结。完成标准仍是上面 T2 一节的那些。另外注意：

- 用 `FEISHU_LITE_APPEARANCE=light|dark` 切外观，按 pid 激活窗口，截图前确认窗口是激活外观（红绿灯有颜色、侧栏文字不发暗）。旧候选是非激活外观，全部重截。
- Messages 主角会话的成品要能看到完整的会议卡片和图片消息，必要时滚动或调整主角会话的消息顺序（只改 JSON）。
- 总结追加到 `kb/sessions/2026-10-21-mock-data-t2.md`，加一节「T2b」，把开头「T2 不可签收」之类过时的结论改成最终状态。

## 共同约束

- 只做自己的任务，做完就停，不开始下一个任务，不改本文件。原因：协调者要按上一个任务的实际产出，定下一个任务的 brief。
- 只改自己范围内的文件。范围外看到的问题写进总结的「交给协调者」，不要顺手改。
- 工作目录 `/Users/reorx/Code/feishu-lite`，分支 master。不建分支或 worktree，不 push、不发布、不打 tag。
- 只 `git add` 自己改的文件，并用 `git commit -m "..." -- <自己的文件>` 只提交这些路径。协调者可能在同一个 checkout 里提交。
- 归协调者的共享文件（见决定表）不要改，要改的内容写进总结的「交给协调者」。
- 不自己开辅助 tab，不委派其他 agent。context 超过 40% 时，停在一个干净的点，在总结里写好接续，然后回复协调者，由协调者开新 tab。
- 功能代码测试先行（BDD）：先写行为测试，看到它失败，再实现。不跑 formatter 或 style linter。
- 后端测试要先进入 `backend/` 目录再跑 `uv run pytest`。在仓库根用 `uv run --project backend pytest backend/tests` 不会切换工作目录，会出现假失败。
- **不要动用户正在用的 App。** 用户日常用的 FeishuLite 是 `mac/.build/DerivedData` 下的 Debug 构建，现在正在运行。
  - 不用 `make run`、`make dev`，也不用 `pkill FeishuLite` 之类按名字结束进程：它们会结束用户的 App。只结束你自己启动的进程，按 pid。
  - 构建 App 时用 `make build DERIVED_DATA=tmp/2026-10-21-mock-data/<任务>/DerivedData`（或绝对路径），不要覆盖 `mac/.build/DerivedData` 里正在运行的那份。`make test` 走 SPM，不受影响。
  - 不读真实的 `~/Library/Application Support/FeishuChat/`，不读写真实钥匙串条目，不改正式偏好域里 App 自己的键，不碰登录项。
- 不连真实飞书或真实邮箱，不读 `tmp/feishu-mail.env`，不往任何聊天发消息，不发系统通知。确实需要真实环境时，停下来问协调者。
- 端口：模拟后端由 App 随机分配端口，一般不需要固定端口。需要单独跑后端调试时，T1 用 18801–18809，T2 用 18811–18819，用前确认空闲。
- **截图**：先跑 `wake-screen`；只截自己启动的模拟实例的窗口（`screencapture -l <窗口 id>`，按 pid 找窗口），不要截到用户的 App 或桌面上其他内容。长时间截图时用 `caffeinate -d`。
- 前几轮踩过的工具坑：
  - 用 AX 设值不会更新 SwiftUI 的 binding，要用真实键入。
  - 长文本键入时，窗口可能中途失去激活；用短文本，并先确认焦点。
  - 系统"键盘导航"是关闭的，不要依赖 Tab 聚焦，也不要改这个全局设置。
- 可以参考但不要依赖 `tmp/2026-10-17-email-reader-finish/u1/tools/` 和 `tmp/2026-10-18-ui-fixes/r8b/tools/` 里的截图、窗口控制脚本。
- 收尾时清理自己启动的东西：App 实例、后端、临时目录、`com.reorx.FeishuLite.mock` 之类的偏好域（如果用了）、caffeinate。只清自己的，证据保留。

## 交付物

- 总结：`kb/sessions/2026-10-21-mock-data-<任务小写>.md`。内容：
  - 做了什么，逐条对照完成标准，附证据路径。
  - 自己做的决定，尤其是数据格式和隔离方式的选择。
  - 未验证项。
  - 首败和工具错误：保留原始输出，不改记为通过。
  - 清理情况。
  - 「交给协调者」。
- 证据：放在 `tmp/2026-10-21-mock-data/<任务小写>/`。
- 提交：代码、测试、数据、文档和总结一起提交。
- tab 里的最后一条回复：提交 hash、总结路径、一句话结论，然后停下。

## 状态

只有协调者改这一节。

| 任务 | 状态 | agent / tab | 结果提交 | 监视器 |
|---|---|---|---|---|
| T1 | 已签收 | `mockdata-t1` / tab `w47:t2`（pane `w47:p2`） | `421c7a3`、`2deb879` | 已结束 |
| T1b | 已签收 | `mockdata-t1b` / tab 标签 mockdata-t1b（pane `w47:p4`） | `8be3af8` | 已结束 |
| T2 | 部分完成：展示数据 `16c5d9c`、外观开关 `a2812bc` 已审；`mockdata-t2` context 45% 停下。截图、入库、README 交给 T2b，等 T1b 签收后派 | `mockdata-t2` / tab `w47:t3` | `16c5d9c`、`a2812bc` | 已结束 |
| T2b | 进行中（2026-10-21 派发） | `mockdata-t2b`（Astra） | — | 待起 |

审阅基线：`2deb879`（T1 签收）。
