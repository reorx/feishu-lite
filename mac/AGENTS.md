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
  - `FeishuChat/` — app target，系统胶水与 UI，按 `Services/` `UI/` `App/` 组织
- 开发方法：新功能 BDD —— 先在 `FeishuChatCore/Tests/FeishuChatCoreTests/` 写行为测试（Swift Testing，`@Test` / `#expect`），再实现；bug 修复 TDD —— 先写复现测试再修

## 命令

```
make build       # xcodegen + xcodebuild Debug 构建（xcbeautify 美化输出）
make test        # FeishuChatCore swift test
make run         # kill 旧实例并启动已构建的 app（不触发构建）
make dev         # build + run
make gen         # 仅重新生成 xcodeproj
make clean       # 清理构建产物与生成的 xcodeproj
```

- 构建产物：`.build/DerivedData/Build/Products/Debug/FeishuChat.app`
- 跑单个测试：`cd FeishuChatCore && swift test --filter <测试名>`
- 改了 `project.yml` 后必须 `make gen`（`make build` 已包含）
- 直接调 xcodebuild 时固定参数：`-project FeishuChat.xcodeproj -scheme FeishuChat -destination 'platform=macOS' -derivedDataPath .build/DerivedData`，并 `set -o pipefail` 后接 `| xcbeautify`

## 签名与 TCC

- Bundle ID：`com.reorx.FeishuChat`。**TCC 授权与 bundle ID + 签名身份绑定，两者都不要随意改动**，否则麦克风/辅助功能等授权会被系统重置
- Debug 签名身份由 `Config/Local.xcconfig`（gitignore）提供；新机器初始化：装好 Apple Development 证书后 `cp Config/Local.xcconfig.example Config/Local.xcconfig` 填 Team ID（从证书提取：`security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`，取 OU 字段）；无证书时回落 ad-hoc 签名，能构建但 TCC 会反复弹窗
- 签名身份变更后用 `tccutil reset <服务名> com.reorx.FeishuChat` 清掉旧授权再重新授权
- Release 必须 Developer ID Application + hardened runtime + notarytool 公证

## 排错顺序

构建怪异时先怀疑环境再怀疑代码：

1. `make clean && make build`（清 DerivedData + 重新生成工程）
2. 检查僵尸进程：`pgrep -lx FeishuChat`、`pgrep -l xcodebuild`
3. SPM 缓存问题：`rm -rf FeishuChatCore/.build`、删 `.build/DerivedData` 下 SourcePackages
4. 以上无效再看代码
