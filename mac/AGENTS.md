# FeishuChat

FeishuChat 的 SwiftUI 客户端：拉起并守护 `../backend` 的 Python 后端子进程，通过 127.0.0.1 上的 REST + SSE 与它通信，负责界面、本地通知和 Dock 角标。项目整体说明见上级目录的 `AGENTS.md`。

## 技术栈

- macOS 14.0+，SwiftUI App lifecycle，Swift 5 语言模式（非 Swift 6 strict concurrency）
- 本地 SPM 包 `FeishuChatCore`（纯逻辑 + 单测）+ app target（系统胶水与 UI）
- 本机工具链：Xcode、xcodegen、xcbeautify（后两者 `brew install xcodegen xcbeautify`）

## 工程约定（重要）

- **一切构建/测试/运行走 Makefile，不用 Xcode GUI。**
- 工程定义的唯一事实来源是 `project.yml`（XcodeGen）。**永远不要手工编辑 `FeishuChat.xcodeproj`**（已 gitignore，`make gen` 随时重新生成）。
  - 加源文件：直接放进 `FeishuChat/` 目录（目录即 sources），然后 `make gen`
  - 改 target 配置 / Info.plist / entitlements / 包依赖：改 `project.yml`，然后 `make gen`
  - `FeishuChat/Info.plist` 和 `FeishuChat/FeishuChat.entitlements` 是 xcodegen 从 project.yml 生成的，不要直接编辑
- 分层规则：
  - `FeishuChatCore/` — 本地 SPM 包，纯逻辑（状态机、编解码、数据模型），**禁止依赖 AppKit**，所有单测在此
  - `FeishuChat/` — app target，系统胶水与 UI，按 `App/` `Model/` `Services/` `UI/` 组织
- 开发方法：新功能 BDD —— 先在 `FeishuChatCore/Tests/FeishuChatCoreTests/` 写行为测试（Swift Testing，`@Test` / `#expect`），再实现；bug 修复 TDD —— 先写复现测试再修

## App 怎么工作

- `Services/BackendSupervisor` 在 Debug 下用 `uv run --project <backend> feishu-lite-backend --port P` 拉起源码后端；Release 直接运行用户用 uv 安装的 `feishu-lite-backend`，不依赖源码目录。启动前检查依赖，缺失时显示安装引导并等待用户重新检测。端口和 token 每次启动随机生成，子进程退出后按退避重启；日志在 `~/Library/Logs/FeishuChat/backend.log`。
- `Model/AppState` 管后端、一条 SSE、模块选择、全局时间、汇总 badge 与类型化通知路由；`Model/MessagesState` 管扫码、会话、隐藏偏好、草稿和滚动锚点，`Model/MailState` 管配置、凭证恢复、邮箱状态与待提醒，`MailState+Reader` 接续列表/分页/正文/显示与已读。工作区按模块重建，状态常驻；Email 已有原生配置页和收件箱阅读器。SSE 事件同步按序分派，每领域恢复任务和邮件列表任务各自合并，不为每事件创建 Task；重启取消旧工作并重置世代。
- 邮件接续先读 `../kb/sessions/2026-10-13-email-configuration-d1.md`。`BackendClient+Mail` 提供全部 typed API，邮件错误不进入聊天登出；`MailKeychain` 以 UUID 精确查询 file-based SecItem：Release service 保持 `com.reorx.FeishuChat.mail`，`#if DEBUG` 使用 `.debug`，绝不回退/迁移另一 service；旧 Debug 缺失凭证须重新输入。自动读取一次，ready + SSE 后才注入。外部后端不自动读取/注入，写失败只保留内存；删除失败的账号 id 存 UserDefaults，重建后显式清理。测试使用假 Keychain/URLProtocol，禁止触碰真实条目。主要配置 UI 已经 F1 假 SecItem 隔离验证；F2b真实测试UUID自身CRUD与production MailState凭证恢复调用通过，HTTP/ready/SSE仍为harness合成；旧共享 service 跨签名互访遇login钥匙串密码授权阻塞；F2c 已验证新 Debug/Release service 真实测试 UUID 双向隔离，历史 ACL 与真实拒绝/锁定仍未验，见 `../kb/sessions/2026-10-14-email-keychain-chat-f2c.md`；fake错误UI已经F1b验证；精确未验项见 `../kb/sessions/2026-10-14-email-reader-f1b-acceptance.md`。
- 已读与通知使用 Core 的 `ViewingContext`，必须包含当前模块；只看旧选中聊天会在 Email 下误清未读。`AppState.updateUnread` 是唯一 `setBadge` 调用点；邮件计数来自整箱快照，离线不归零。`pendingMailRoute` 仅是待消费路由；ViewingContext 邮件目标必须来自 `mail.displayedBodyRoute`（当前渲染完成），不能用 `selectedRoute`/HTTP 成功代替。通知点击由外壳合并调用 `loadPendingMailRoute()` / `mail.openRoute()`，等待能力和邮箱身份，只消费最新目标。行为说明见 `../kb/docs/module-shell.md`。
- `MailNotificationCoordinator` 串行消费权威 pending；系统操作统一注入 `LocalNotificationCenter`，测试必须使用 recorder。投递成功/明确抑制后才整批 ack，未确认记录不淘汰。持久 intent 的 `handled=false` 是未知结果，通知中心无条目不能推断成功；保留 pending，由 Email“再次提醒”显式恢复。去重/清理/唤醒与崩溃窗口见 `../kb/docs/email-foundation.md` 和 `../kb/sessions/2026-10-14-email-notifications-e.md`。
- 阅读器接续先读 `../kb/sessions/2026-10-13-email-reader-d2.md`。HTML 使用非持久 WKWebView、禁 JS、CSP 和首载前编译挂载 block-all 规则；`MailHTMLLoadGate` 与两 WK delegate 的 router 是生产调用链。规则失败不得加载；只用户 HTTP(S) 点击外开。纯文本用只读、可选择的NSTextView，禁富文本/自动链接/数据检测；按实际布局恢复文字位置，最近8封位置与正文摘要仅存内存，身份/正文变化失效。HTML 用公开 `interactionState` 与有界内存文档会话缓存（最近8封、每份256KiB），不保留WK/DOM。R1 在规则挂载后恢复导航，精确URL的document例外另由CSP/frame与delegate限制主框架，只有当前新navigation完成可提供显示证明。F1 已验证原renderer实际隔离和外开；R1屏幕落点和新scheme安全已通过F1b独立复验；浅色/拖宽/cursor恢复/fake凭证错误UI亦已补齐。实现依据见 `../kb/sessions/2026-10-14-email-html-scroll-r1.md`，纯文本R2自动交付见 `../kb/sessions/2026-10-14-email-plain-scroll-r2.md`，原生落点、拖宽换行、深浅色、选择复制及只读交互已通过F1c独立复验，见 `../kb/sessions/2026-10-14-email-reader-f1c-acceptance.md`；真实中文组字/精确旧layout仍未验；剩余精确未验与隔离差异见 `../kb/sessions/2026-10-14-email-reader-f1b-acceptance.md`；F2a主要真实系统通知/点击/跨进程ack/精确清理/Dock已验，未知提示布局R3已由F2b独立复验关闭P2；权限切换等未验见F2a报告；F2b测试UUID自身SecItem、隔离生产Supervisor生命周期与全量通过，合成唤醒/聊天不代表真实睡眠或完整回归，准确范围见 `../kb/sessions/2026-10-14-email-system-integration-f2b.md`。F2b 的旧共享 service 授权框已触发 R4；双配置 service 隔离、精确操作与延后删除自动验证通过，真实测试 UUID 双配置独立复验及限定合成隐藏取消/扫码/邮箱故障期间聊天已通过 F2c，Return 自动化/中文 IME 留未验，见 `../kb/sessions/2026-10-14-email-keychain-chat-f2c.md`。
- 接口模型、SSE 解析、通知策略、消息合并和排序都在 `FeishuChatCore`，改这些行为先改那里的测试。
- **`@Observable` 类里标了 `@ObservationIgnored` 的属性，视图不能直接或间接依赖**（包括由它算出来的计算属性），否则视图收不到变化。给视图用的派生值要存成被观察的属性，参考 `Conversation.rows`。
- 显示"今天/昨天"这类相对时间的视图，"现在"要从环境值 `\.today` 取（`AppState.today`，跨天、改时区、唤醒时更新），不要在视图里直接用 `Date()`，否则过了零点标签不会变。
- 输入框是包了一层的 `NSTextView`（`UI/ComposerView`），为的是拿到输入法的组字状态：候选词没上屏时回车不能发送。不要换回 `TextField` / `TextEditor`。
- 主窗口是单例 `Window`，关掉窗口 App 不退出；窗口关掉之后要用 `WindowManager.show()` 重新打开。

### 调试用的环境变量

`open` 启动的 App 不继承 shell 环境，要用 `open -n --env KEY=value <app>` 传。

| 变量 | 作用 |
|---|---|
| `FEISHU_LITE_HOME` | 后端的数据目录（凭证和缓存），不设就是 `~/Library/Application Support/FeishuChat` |
| `FEISHU_LITE_BACKEND_URL` + `FEISHU_LITE_TOKEN` | 直连一个已经在跑的后端，不拉子进程 |
| `HTTPS_PROXY` / `HTTP_PROXY` | 后端访问飞书走的代理，验收"断网"场景时用 |

## 命令

```
make build       # xcodegen + xcodebuild Debug 构建（xcbeautify 美化输出）
make build-release # Universal Release；默认 Developer ID 签名
make dmg         # 将 Release App 打包到 dist/
make test        # Core 单测 + App Model/Services 隔离调用测试（无 UI）
make run         # kill 旧实例并启动已构建的 app（不触发构建）
make dev         # build + run
make gen         # 仅重新生成 xcodeproj
make clean       # 清理构建产物与生成的 xcodeproj
```

- 构建产物：`.build/DerivedData/Build/Products/Debug/FeishuChat.app`
- 跑单个测试：`cd FeishuChatCore && swift test --filter <测试名>`
- App 状态/布局调用测试：`swift test --filter <测试名>`；`mac/Package.swift` 直接编译 App 的 Model/Services 与邮件视图，测试网络用 URLProtocol、通知/窗口用 recorder、布局用无窗口 NSHostingView，不启动 App 或真实后端。
- 改了 `project.yml` 后必须 `make gen`（`make build` 已包含）
- 直接调 xcodebuild 时固定参数：`-project FeishuChat.xcodeproj -scheme FeishuChat -destination 'platform=macOS' -derivedDataPath .build/DerivedData`，并 `set -o pipefail` 后接 `| xcbeautify`

## 签名与 TCC

- Bundle ID：`com.reorx.FeishuChat`。**通知授权与 bundle ID + 签名身份绑定，两者都不要随意改动**，否则授权会被系统重置
- 通知授权被拒绝后系统不会再弹框，`requestAuthorization` 直接报 "Notifications are not allowed for this application"；只能在系统设置 → 通知 → FeishuChat 里手动打开
- Debug 签名身份由 `Config/Local.xcconfig`（gitignore）提供；新机器初始化：装好 Apple Development 证书后 `cp Config/Local.xcconfig.example Config/Local.xcconfig` 填 Team ID（从证书提取：`security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`，取 OU 字段）；无证书时回落 ad-hoc 签名，能构建但 TCC 会反复弹窗
- 签名身份变更后用 `tccutil reset <服务名> com.reorx.FeishuChat` 清掉旧授权再重新授权
- Release 必须 Developer ID Application + hardened runtime + notarytool 公证

## 排错顺序

构建怪异时先怀疑环境再怀疑代码：

1. `make clean && make build`（清 DerivedData + 重新生成工程）
2. 检查僵尸进程：`pgrep -lx FeishuChat`、`pgrep -l xcodebuild`
3. SPM 缓存问题：`rm -rf FeishuChatCore/.build`、删 `.build/DerivedData` 下 SourcePackages
4. 以上无效再看代码
