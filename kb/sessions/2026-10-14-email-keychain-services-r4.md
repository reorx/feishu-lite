---
created: 2026-10-14
tags:
  - email
  - keychain
  - configuration
  - phase-r4
---

# R4：按 Debug / Release 隔离邮件钥匙串 service

## 概要

F2b 的 Apple Development Debug 与 Developer ID Release 互访旧共享 service 时出现 login 钥匙串密码授权框，触发原计划阶段 D 的既定隔离条件。本次在当前 master、开始 HEAD `76da70f`（协调 brief 所列 F2b 基线 `284fbfc` 之后）落实 R4：Release 保留 `com.reorx.FeishuChat.mail`，Debug 使用 `com.reorx.FeishuChat.mail.debug`。生产代码只增加编译条件与说明，共 5 行；原有统一 query 保证 copy/add/update/delete 及 MailState 延后删除均匹配当前 service + 精确 UUID。

先写实际查询捕获与 MailState 调用测试，4 个新增测试在旧代码下失败，修复后通过。相关 Debug/Release 测试各 7 项通过，完整 `make test` 为 Core 74 / App 96 项通过；Debug 工程构建与独立未签名 Universal Release 编译通过。没有启动 App、真实 SecItem、GUI、邮箱或后端服务，自动 fake SecItem 不代表真实 OS 授权/互访验收通过。代码和必要文档同次提交，不修改协调文件，不改后端、阅读 UI、通知、签名配置或 bundle，不创建分支/worktree、不 push/发布、不委派。

## 修改的文件

- `mac/FeishuChat/Services/MailKeychain.swift`：`#if DEBUG` 选择稳定 `.debug` service，Release 常量保持原值；所有系统调用与错误处理不变。
- `mac/Tests/FeishuChatStateTests/MailKeychainTests.swift`：按捕获到的 service/account 寻址的内存 SecItem recorder；新增同 UUID 独立读/更新/删除与双 canary、缺失不回退和 update→add 精确创建测试。
- `mac/Tests/FeishuChatStateTests/MailIntegrationTests.swift`：生产 MailState + MailKeychain + URLProtocol，验证缺失提示/显式重读/重新输入保存，以及删除失败跨重建重试（当前条目存在/缺失两种输入）。
- 根/mac `AGENTS.md`、`kb/docs/email-foundation.md`：同步当前 service、升级行为、历史 ACL 与自动/真实边界。
- `kb/known-issues.md`：把已触发但未实施的 R4 状态改为自动交付、真实复验仍待做；其他 UI/系统/真实邮箱未验项保持。
- `kb/next-up.md`：移除已完成的实现待办，登记协调者安排独立 SecItem 复验后的最小检查。本报告为新建交接文档。

## service 策略与兼容性边界

| 编译配置 | service | 既有配置与缺失行为 |
| --- | --- | --- |
| Debug，定义 `DEBUG` | `com.reorx.FeishuChat.mail.debug` | 旧 Debug 的缓存账号在新 service 无条目时给出现有“重新输入专用密码”提示；手动保存只写新 service |
| Release，未定义 `DEBUG` | `com.reorx.FeishuChat.mail` | service/account 查询与之前一致，既有正式凭证不会因本次改名失联 |

不自动探测、读取、迁移、更新或删除另一 service。旧 Debug 创建的共享条目保留；旧待删 UUID 在新 Debug service 缺失时按原有幂等删除语义消除记录，不删除旧共享条目。失败清理仍仅持久化非秘密 UUID，重建或重试不会跨 service；无新增持久格式，也不把 service 或密码写入待删列表。

此修复隔离钥匙串命名，不隔离 mail.db/UserDefaults，也不能将 `FEISHU_LITE_HOME` 或替换 HOME 当作 OS 钥匙串物理隔离。沿用 file-based SecItem，不设置 data-protection/access-group/synchronizable，不改 ACL 或正式签名/bundle。Release 保留历史条目的 ACL；如果旧共享条目由另一签名创建，Release 访问仍可能需要系统授权，本次没有尝试修正该历史条目，也不承诺其授权框消失。未来改签名的同配置访问亦不是本次保证。

每账号自动读一次、ready + SSE 后注入、后端重启复用内存、外部模式不自动读/注入、写失败只留内存和安全错误分类均保持；全量测试覆盖既有行为。升级 Debug 没有密码时不从旧共享条目恢复，不后台反复读，也不会错误注入对方凭证。

## 自动验证与红绿证据

日志和可复用检查脚本在 `tmp/2026-10-14-email-reader/r4-keychain-services/`（gitignore）。没有本次截图，未进行 GUI 验收。

| 命令 / 证据 | 结果 |
| --- | --- |
| `cd mac && swift test --filter 'configuration\|missingCurrentCredential'`，`tests-red.log` | 旧实现下 4 项失败 / 20 个断言问题；证明 Debug 操作旧共享 service、读到对方密码并误更新/删除 |
| 同命令，`tests-red-final.log` | 补入“延后删除的本 service 条目缺失”参数后，4 项失败 / 22 个断言问题；删除仍落到旧共享 service |
| `swift test -v --filter 'MailKeychainTests\|configuration'`，`tests-debug-green.log` | Debug 7 项通过（新增 4 项，延后删除另含 2 组输入，原 OSStatus 含 6 组输入） |
| `swift test -c release -v --filter 'MailKeychainTests\|configuration'`，`tests-release-green.log` | Release 相同 7 项通过；生产默认 MailKeychain 使用旧 service，测试没有传入两个 service 字符串代替编译选择 |
| `cd mac && make test`，`tests-full.log` | Core 74 / App 96 项通过，App 从 92 增至 96；首轮全量通过，不循环复跑 |
| `cd mac && make build`，`build-debug.log` | Debug Build Succeeded，现有 Apple Development 签名流程成功；没有安装或启动 |
| `make build-release DERIVED_DATA='../tmp/2026-10-14-email-reader/r4-keychain-services/DerivedData-release' RELEASE_XCARGS='CODE_SIGNING_ALLOWED=NO'`，`build-release.log` | Universal Release Build Succeeded，仅本次编译关闭签名；`lipo` 确认 x86_64 / arm64，不代表签名、公证或发布验收 |
| `uv run --no-project tmp/2026-10-14-email-reader/r4-keychain-services/verify-build-configurations.py`，`configuration-check.log` / `build-configurations.json` | 实际 Xcode 工程 App Debug 的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`，Release 为空；生产测试模块与 test target 的实际 swiftc 参数也仅 Debug 有 `-DDEBUG` |
| `resource-check.json`、`cleanup-preferences.json`、`cleanup-*.log` | 自动测试进程 0、本次偏好 plist 残留 0；sim/browser 无本次待清资源 |

构建配置检查读取实际工程的 `-showBuildSettings -json`，仅保留 configuration、Swift 条件/优化、bundle、签名身份等非秘密字段；另解析 `-v` 测试日志中的生产 `FeishuChatState` 与 `FeishuChatStateTests` 编译命令。`project.yml` / Package.swift 已有正确的配置条件，无需新增定义或修改发布流程。两配置均操作各自生产默认 query，测试内只按明确预期的配置为当前/另一 service 播种内存条目，随后检查所有捕获查询与实际读写结果。

检查脚本首轮只支持分离写法 `-D DEBUG`，实际日志是 `-DDEBUG`，因此工具断言失败；修正解析器后通过，`configuration-check-first.log` 保留该工具首败，不作为产品或编译条件缺陷。资源首查发现删域后遗留的 9 个本阶段测试 plist，已按记录的精确 UUID suite 清除；`resource-check-first.*` 保留首查。未跑 formatter/style linter，没有修改后端或重复 pytest；F2b 的后端 301 项只是既有基线，不记成本次检查。

## 清理结果

所有自动测试和构建进程已退出，未启动自建监听服务、App、浏览器或模拟器，未创建/读取真实钥匙串条目或系统通知。测试 UserDefaults 使用独立 `r4-mail-test-<UUID>` suite 并 defer 删域/同步；收尾只按本次资源检查记录的 9 个域逐一清除其 plist，最终该前缀文件与测试进程均为 0，不读取或删除用户正式偏好。

执行 `mac-dev-cleanup --only browser --min-age 2` 与 `--only sim`，dry-run/实际均 nothing to clean。3 个不足 2 小时的其他 browser 会话保持，不关闭其他执行者资源。保留 gitignore 的日志/脚本、独立 Release 构建产物和正常 Debug/SPM 构建缓存，未运行 `make clean`。

## 遗留问题与独立验收最小步骤

本 tab 仅自动实现与验证。真实双配置 SecItem 行为、真实拒绝/锁定分类和历史 ACL 授权仍未验；整体 F 与其他聊天/GUI/真实邮箱余项没有签收。以下由协调者安排独立 tab，先读桌面测试约定并遵循 context 门槛，不在开发 tab 补做。

1. 用最新源码构建 Debug/Release 的隔离 helper，保留 production MailKeychain 原码；两种真实签名沿用 Apple Development / Developer ID。确认实际 configuration、service、签名，不用同签双副本冒充；只使用新随机测试 UUID/canary，密码仅进程内存。
2. 同一个主 UUID：先仅 Debug 写入，再由 Release 精确读取，应为 notFound，不探测 Debug service；Release 缺失删除不得影响 Debug。再由 Release 写另一随机值，各自读取应精确匹配自己的密码。全程不得输入系统密码或放宽 ACL，若出现授权框记为阻塞，停止该路径。
3. 分别更新和删除各自主 UUID，另一配置及两侧 canary 仍精确可读；对称验证缺失读取/幂等删除不 fallback。最后由创建方在各自 service 精确删除所有测试 UUID 并确认缺失，不枚举或访问历史用户条目。
4. 用合成 HTTP 与隔离偏好、production MailState 验新 Debug service 缺失：显示重新输入入口、一次自动读、无凭证注入；输入合成专用密码后只写本 service。用注入的单次删除失败与独立 pending UUID 验重建后的精确清理，不能通过锁住整把钥匙串制造错误。
5. Release 兼容性只用自己创建的隔离测试条目：以旧 service 同 UUID 的 Release 签名创建，再由当前 Release 精确读取。不要用旧 Debug 创建的共享条目绕过 ACL 来验证，也不要读取用户现有正式账号。

## 相关文档

- [协调计划 R4](../plans/2026-10-13-email-reader-coordination.md) — 本次任务与约束，只读未修改。
- [邮件阅读器原计划](../plans/2026-10-13-email-reader-plan.md) — 阶段 D 已触发的配置 service 隔离条件，只读，完整阶段未勾完成。
- [D1 配置与凭证报告](2026-10-13-email-configuration-d1.md) — query、恢复与持久清理契约。
- [F2b 系统集成报告](2026-10-14-email-system-integration-f2b.md) — 不同签名的实际授权框与实现触发证据。
- [邮件基础文档](../docs/email-foundation.md) — 本次更新 service、升级与历史 ACL 边界。
- [Known issues](../known-issues.md)、[Next up](../next-up.md) — 更新当前状态及真实独立复验接续。
