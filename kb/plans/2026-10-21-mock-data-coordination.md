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
| 共享文件 | 根 `AGENTS.md`、`mac/AGENTS.md`、`kb/known-issues.md`、`kb/next-up.md`、plan 的勾选、本文，都由协调者在签收后更新。`kb/docs/mock-data.md` 归 T1，T2 只在格式说明需要补充时改它。README 归 T2，只加截图区 | 协调者 |

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
| T2 展示数据、截图、README | `mockdata-t2` | Astra | T1 签收 | 截图由协调者审；README 的 `<picture>` 结构和图片路径可用 |

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

### T2 展示数据、截图、README

T1 签收后由协调者补全本节（依据 T1 的实际数据格式和启动方式）。

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
| T1 | 计划中 | — | — | — |
| T2 | 计划中 | — | — | — |

审阅基线：`a0535d7`（开工前的 HEAD）。
