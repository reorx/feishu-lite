---
created: 2026-10-21
tags:
  - app-icon
  - macos
  - readme
  - verification
---

# T4：App 图标透明边缘

## 概要

原图是 1254×1254 RGB，圆角方块外的白背景和阴影已烘焙进像素，README 深色模式出现白框。已把源图改为 1024×1024 RGBA，保留鸟、lite 文字、原有底色和质感，去除外部白底；重新生成全部 10 个 App 图标资源。透明度检查、236 个 Swift 测试、隔离 Debug 构建、系统图标渲染和 README 深浅预览均通过。未修改 README 内容或 App 逻辑。

执行基线是 `feaac59`（在用户所述 `bfc414b` 后仅新增 T4 派发文档）。证据统一在 `tmp/2026-10-21-mock-data/t4/`，以下证据文件名均相对于该目录。按用户明确授权直接完成验证和提交，预览留给用户与协调者最终审阅。

## 修改的文件

- `mac/Artwork/AppIcon.png`：透明源图。
- `mac/FeishuLite/Assets.xcassets/AppIcon.appiconset/` 的 10 个 PNG：由现有 `uv run scripts/generate-app-icon.py` 重新生成，Contents.json 无变化。
- 本总结。生成脚本和项目图标设置未改；没有修改 `mac/FeishuChat/` 旧资源或共享文档。

## 网格、抠图与阴影

- 画布 1024×1024；底板 824×824，四边各留 100 px。
- 用 macOS `CALayer.cornerCurve = .continuous`、`cornerRadius = 185.4` 生成系统连续圆角，4 倍分辨率光栅化后 Lanczos 降采样，避免用普通圆弧圆角代替。代码在 `mask.swift`。
- 原图副本保留为 `original.png`。取原图 `(105, 102, 1149, 1146)` 的 1044×1044 内侧区域，缩至 824×824，再套圆角蒙版。鸟、字和底板仍来自原图，不重新绘制、不调色。裁切略向内避开原先与白背景混合的轮廓；底板轮廓按新网格调整。
- 投影为纯黑，水平偏移 0，向下 12 px，零 spread，50% 不透明度，Pillow GaussianBlur 半径 28。Photoshop 模糊和 Pillow 高斯模糊的算法并非像素等价，这里保留参考参数，实际视觉结果见浅色对比。蒙版外仅有透明黑投影，四角 alpha 为 0。
- 可复现制作脚本 `remake.py`；透明度检查 `check-alpha.py`；系统渲染 `render-icons.swift`；对比拼图 `compare-system.py`。这些任务脚本均依约留在 tmp，Python 用 `uv run --with pillow` 执行。

参考与边界：

- [Apple 当前 App icons HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons) 和 [Design Resources](https://developer.apple.com/design/resources/) 已转为 Icon Composer 分层、系统遮罩方式。本次按 T4 约定保留传统 macOS PNG asset catalog，不把旧式网格冒称为当前分层资源规范。
- [Apple 开发者论坛关于旧式图标的讨论](https://developer.apple.com/forums/thread/670578) 中，2024 年参与者给出的模板参数为 824×824、185.4 连续圆角、28 px 阴影半径、下移 12 px、黑色 50%。这是论坛参与者的参数说明，不是 Apple 员工的保证；全文通过 fetch-fallback 读取，存于 `apple-forum.md`。
- Apple macOS 12 Photoshop / Sketch 模板直链返回 403，未能直接读取原 PSD/Sketch 模板。因此连续圆角用系统 API 生成，阴影依据上述模板说明复现；不声称读取了 PSD 的精确滤镜数据。

## 完成标准与证据

| 标准 | 结果与证据 |
|---|---|
| 源图及 10 个 PNG 的透明通道与四角 | 全部 RGBA、四角 alpha=[0,0,0,0]；源图 1024×1024。`alpha-after.log`，修复前失败记录 `alpha-before.log` |
| 新旧源图深浅对比 | `source-dark.png`、`source-light.png`；深色使用 #0d1117，白底和白色光晕已去除 |
| 系统实际图标 | `system-dark.png`、`system-light.png`；包含 512、128、32 px 的新旧对照；原始 PNG 为 `system-{old,new}-{size}.png`，路径和测量见 `system-render.log`、`system-alpha.log` |
| README 深浅预览 | `readme-dark.png`、`readme-light.png`，1280×1100 浏览器视口；logo 外透明，无白框 |
| README 页面检查 | `preview-dark.json`、`preview-light.json`：页面宽 1280，无横向滚动；表格 clientWidth/scrollWidth 都是 815；两张展示图宽均为 380；深浅 currentSrc 对应正确 |
| Swift 测试 | `cd mac && make test` 退出 0；Core 103 + App 133 = 236 个测试通过，`make-test.log` |
| 隔离构建 | `make build DERIVED_DATA=/Users/reorx/Code/feishu-lite/tmp/2026-10-21-mock-data/t4/DerivedData` 成功，`make-build.log` |

### macOS 26 的显示结论

本机 macOS 26.7.1（25G241），通过 `NSWorkspace.shared.icon(forFile:)` 读取旧 T2 构建和新 T4 构建，未启动两个 App。旧图被系统规整到圆角方块，内部又保留原图的白背景，产生明显的宽浅色外框。新图的内容填充正常，宽外框消失。

系统输出并非逐像素照搬源 PNG：新图仍有很细的浅色轮廓/底板边缘，512 px 时最明显。源 PNG 在深色对比中没有这一圈，说明该边缘来自系统渲染。可以确认当前 NSWorkspace 路径会处理旧式图标，不能简单声称“透明后系统完全不加底板”；也不能从旧图单独推断其整个宽白框都是系统新增的，因为旧源图本来就有白底。这里只验了上述三个尺寸、当前系统和 API 路径，没有实际打开 Finder、DMG 或动 Dock。

## README 预览服务

- 工具：已安装的 `gh-markdown-preview` v1.12.0，GitHub Markdown API 渲染与 GitHub CSS。遵循 `~/.claude/docs/GITHUB_README.md` 第 4 节。
- URL：**http://127.0.0.1:6419/**。
- `gh` 父进程 PID **8049**（PPID=1），实际监听子进程 PID **8078**。`start-preview.py` 用 `subprocess.Popen(..., start_new_session=True)` 启动，日志 `preview.log`，父 PID 在 `preview.pid`。
- 主题跟随浏览器 prefers-color-scheme。Chrome DevTools → 命令菜单 → Show Rendering → Emulate CSS media feature prefers-color-scheme → light / dark。自动验收使用 `agent-browser set media`，未改系统外观。
- 服务继续运行。用户确认后协调者可按 PID `kill 8078 8049` 关闭，先确认进程仍属于本预览。

## 首败和工具错误

- 修改前运行 `check-alpha.py` 失败：11 个文件均无透明通道，且源图不是 1024×1024；完整输出 `alpha-before.log`。修改后同一脚本通过。
- Apple Photoshop 模板下载返回 `curl: (56) The requested URL returned error: 403`，随后挂载报 `hdiutil: attach failed - No such file or directory`，没有挂载成功。Sketch 模板重试也返回 403，原始日志 `template-download.log`。失败没有记为模板读取成功。
- Firecrawl 得到的论坛正文是验证页，留在 `shadow-search.json`；改用 fetch-fallback 成功，日志 `fallback.log`、正文 `apple-forum.md`。
- 首轮浏览器截图早于异步 Markdown 渲染，页面为空。原图与检查输出保留为 `readme-*-before-load.png`、`preview-*-before-load.json`。等待 logo 元素出现并核对页面后重截；最终的两张预览已人工逐张查看，不能用 open 成功当作正文已加载。

## 清理情况

已关闭 `mockdata-t4` 浏览器会话；`mac-dev-cleanup --only browser --min-age 2` 返回 nothing to clean（`cleanup.log`）。fetch-fallback 的临时标签自动关闭。未启动模拟 App、后端、模拟器或 caffeinate，未修改偏好域，未访问真实账号、钥匙串或通知。旧/新构建和证据保留，用户正在使用的 App 未被替换或结束。仅 README 预览服务按要求保留。

## 未验证项与交给协调者

- 实现和自动/视觉验证已完成。用户对预览的最终确认由协调者收取；确认后关闭上述服务。没有 push、发布或打 tag，GitHub 线上实际缓存显示本次未验证。
- 当前系统仍会给旧式图标增加细浅色轮廓；本次未扩大范围迁移 Icon Composer。新旧系统对比图可供判断是否需要另立任务。
- 共享 AGENTS.md、known-issues、next-up 和协调记录依分工未改。本次不需要新增功能说明；协调者可在 T4 签收时链接本总结并记录预览清理状态。

## 相关文档

- [模拟数据协调计划](../plans/2026-10-21-mock-data-coordination.md) — 本次 T4 范围、完成标准与共享文件约束。
- [模拟数据计划](../plans/2026-10-21-mock-data-plan.md) — 总体背景与隔离要求。
