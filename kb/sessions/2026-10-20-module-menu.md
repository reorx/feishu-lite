---
created: 2026-10-20
tags:
  - macos
  - ui
  - sidebar
---

# 模块切换改为侧栏工具栏图标与标题菜单

## 概要

按用户最终确认，删除侧栏原有的整排 Messages / Email 按钮。两个模块图标放在左侧栏右上角、系统侧栏开关左边，保留当前模块选中态和各自未读角标。下面以 Messages / Email 标题下拉切换模块；Email 右侧同一行保留独立的收件箱文件夹下拉。没有改聊天或邮件的同步、已读和通知规则。

## 修改的文件

- `mac/FeishuLite/UI/ShellComponents.swift`：模块标题菜单、工具栏图标与共享侧栏容器。
- `mac/FeishuLite/UI/RootView.swift`：向两个工作区传递同一模块选择与未读快照。
- `mac/FeishuLite/UI/MainView.swift`、`EmailWorkspace.swift`：图标 toolbar 挂到 sidebar 内容，未登录和能力检查页面也保留入口。
- `mac/FeishuLite/UI/ChatListView.swift`、`MailInboxList.swift`：合并标题行；隐藏会话子页保留返回入口。
- `mac/Tests/FeishuLiteStateTests/ScrollAnchorTests.swift`：适配列表的模块控件参数，原有滚动恢复断言保留。
- `mac/AGENTS.md` 与模块外壳文档：记录布局约定及最终行为。

## 验证

- `make test` 通过：Core 103 项，App 125 项，含外壳最小窗口与模块切换滚动恢复。
- `make build` Debug 成功。
- 独立 bundle `com.reorx.FeishuLite.module-menu-ui` 配合本机合成后端验收，不读取真实聊天和邮箱。
- 确认工具栏两个图标均位于分隔线左侧，双向点击切换正确，无障碍标签和未读数分别对应两个模块。
- 打开标题菜单，确认两个模块及未读数，选择 Messages 成功切回；Email 与收件箱菜单独立。
- 窗口宽 800pt、侧栏宽 240pt 时图标和同行菜单完整显示；侧栏收起后保留顶部模块图标。
- 截图和 AX 证据：`tmp/2026-10-20-module-menu/`，最终效果以 `final-email.png`、`final-messages.png`、`final-menu.png`、`final-collapsed.png` 为准。目录内另有早期方案截图，不代表最终布局。

## 注意事项

模块图标使用 sidebar 内容上的 `.toolbar` 和 `.automatic` placement。把它们放在整个 NavigationSplitView 上并使用 `.navigation` 会出现在分隔线右侧。两个图标各用独立、稳定 id 的 ToolbarItem，避免将两个按钮包成一个工具栏项后出现无障碍标签混用。

## 遗留问题

本次实机截图为浅色模式；未另跑深色截图。没有新增数据行为或修改正文布局。

## 相关文档

- [模块外壳](../docs/module-shell.md) — 更新模块切换位置与菜单规则。
