---
created: 2026-10-13
tags:
  - email
  - python
  - storage
  - mime
  - phase-c1
---

# 邮件 C1：领域模型、独立存储与 MIME/HTML 基础

## 概要

在当前 master 完成协调文档 C1 范围：`mail/` 共享 Pydantic 模型、严格标识与游标、独立 mail.db、摘要/原始正文分离、未读快照与通知 pending/ack 存储、IMAPClient BodyData 正文选择、编码解码和 HTML 净化。先写失败行为测试，再实现，并对复查发现的问题先复现再修复。coordinator 审阅后按原计划收敛 HTTP(S) 用户链接规则，保留合法 IP 与内网链接。最终后端全量 **123 项通过（84 项 C1 + 39 项既有回归）**。

未连接真实邮箱、读取 env 或正式缓存、修改 App、接入邮箱生命周期/API/SSE、开启 C2、委派、push 或发布。协调文档未改，阶段签收留给 coordinator。Email 仍不可配置/阅读，后端 `/status` 尚未宣告 mail feature。

## 修改的文件

- `backend/src/feishu_lite/mail/{types,store,mime,html,__init__}.py`：全部 C1 实现，无导入时联网或启动副作用。
- `backend/tests/mail/{test_foundation,test_mime}.py`：合成行为样本；无真实邮箱、主题、正文、身份或凭证。
- `backend/pyproject.toml`、`uv.lock`：通过 uv add 引入 IMAPClient ==4.1.0、nh3 >=0.3.7、显式 pydantic 依赖；锁定实测 nh3 0.3.7、pydantic 2.13.5。larkx 固定 git commit 不变。
- `kb/docs/email-foundation.md`、本报告、原计划：当前行为、接续接口和有证据的 C1 子项。
- `AGENTS.md`、`backend/README.md`：当前实现状态与开发入口。

## 红绿测试证据

全部在 `backend/` 执行 `uv run pytest`，运行时 CPython 3.12.12，pytest 9.1.1。日志目录 `tmp/2026-10-13-email-foundation-c1/`（gitignored，无截图）：

| 文件 | 证据 |
| --- | --- |
| `tests-red.log` | 首次行为测试在模块未实现时 2 项导入错误；这是导入期红灯，非运行期断言失败 |
| `tests-first-green.log` | 首批 50 项 C1 通过 |
| `tests-review-red.log` | 4 项运行期失败：最长中文标识无法回解、旧 UID 加入新提醒、允许水位间隙、附件文件名回退丢失 |
| `tests-review-green.log` | 上述修复后 64 项通过 |
| `tests-catalog-red.log` | 2 项失败：缺少未选择文件夹目录存储、畸形 RFC2231 原始 Unicode 异常冲出批次 |
| `tests-catalog-green.log` | 修复后 66 项通过 |
| `tests-full.log` | 中间全量 105 项通过，4.28 秒 |
| `tests-worker-red.log` | 工作线程净化场景缺少脱离 SQLite 的内部原始正文读取入口，1 项失败；真实库 FETCH parser 契约已通过 |
| `tests-final.log` | 链接规则收敛前全量 107 项通过，4.12 秒；当时 C1 为 68 项 |
| `tests-links-red.log` | 8 个合法 IPv4/IPv6、localhost、单标签和内网域名用户链接运行期失败；先补测试再改实现 |
| `tests-links-green.log` | 链接调整后 84 项 C1 通过，包括畸形 host/IPv6/端口 URL 安全移除与既有恶意 HTML 回归 |
| `tests-links-full-final.log` | 最终后端全量 **123 项通过，4.15 秒**；C1 为 84 项，既有回归 39 项 |

最终 git diff --check 通过。没有运行 formatter/style linter、App 构建或 UI 验收。真实 IMAPClient `parse_fetch_response` 解析合成 wire FETCH，得到实际 `BodyData([children], subtype, ...)`，再由生产函数选中 HTML section；不是自造同名 fake 类型。另有库 `BodyData.create` 的嵌套、related、转发与附件样本。

## 具体模型和调用约定

共享模型集中在 `mail/types.py`：MailAccount、MailFolder、MailKey/MailCursor、MailHeaders/MailAddress、MailSummary、BodyPart/BodySelection/Attachment、RawBody/MailBody、SyncState/PendingBatch、MailLimits/ParseResult。没有通用聊天/邮件消息层。

Python 内部叫 `account_id`，C3 在既定 API 边界映射到 `mail_account_id`；文件夹 id 是库已解码的真实标识，不能由显示名称猜测。账号生成 UUID、更换地址生成新 id 是 C3 生命周期的责任；Store 拒绝同一 id 更改地址。模型不含密码字段。

标识 payload 为规范紧凑 UTF-8 JSON 数组 `[1,"message",account,folder,uidvalidity,uid]`，无 padding 的 base64url；游标仅把类型改成 `cursor`。解码拒绝类型混用、额外/缺少项、未知版本、非规范编码、空/控制字符身份、字符串/布尔 UID 与越界数字。UID/UIDVALIDITY 为 1..2^32−1，UIDNEXT 允许 2^32；身份各最多 512 字符，对外编码最多 8192 字符，覆盖最长 Unicode 身份往返。编码是标识，不是认证或加密。

```python
from pathlib import Path
from feishu_lite.mail.store import MailStore
from feishu_lite.mail.types import MailFolder, MailKey, MailSummary

store = MailStore(Path(data_dir) / 'mail.db')  # 事件循环所属线程
store.save_account(account_id, address)       # 仅配置，不含密码
store.save_folders(account_id, all_list_folders)  # LIST 全量快照，无需 SELECT
store.reset_folder(account_id, inbox, uidvalidity, uidnext)  # 首连/世代变化
page = store.page(account_id, 'INBOX')         # 初始 100
next_page = store.page(account_id, 'INBOX', cursor=page.next_cursor)  # 后续 50
state = store.sync_state(account_id, 'INBOX')
```

`save_summaries` 用于历史摘要/flags 缓存，**不更新水位或触发提醒**。Store 的 page 仅分页当前缓存；C3 需按服务端 UID 列表倒序切片补缓存，不能拿该接口冒充全箱历史已下载。显式 limit 为 1..100。`cached_uids` 用于删除对账；`get_summary` 返回 None 表示已删/未缓存。`save_folders` 是完整目录快照，目录消失会级联失效其缓存；切勿传局部目录页。

`reset_folder` 相同 UIDVALIDITY 只刷新目录，保存水位/缓存；改变世代才重建，并重置同步与通知基线为新 UIDNEXT。旧键读取/写入和 ack 抛 `stale_message`，旧账号/文件夹/世代游标抛 `stale_cursor`。缺失文件夹的直接状态读取为 `folder_missing`。账号移除级联删自己的目录、状态、摘要、正文、未读和通知，不碰另一账号或 cache.db。

### 未读、通知与原子操作

- `replace_unseen(account, folder, validity, set_of_uids, checked_at=unix_seconds)` 原子替换整箱未读快照，更新已缓存摘要和 `\\Seen`，保留其他 flags，返回新变已读的 MailKey 列表供 C3 清理已递送通知。计数来自 unseen 表；未缓存 UID 也计入。
- `commit_arrivals(summaries, sync_next=N, batch_id=B, notify_next=N)` 原子保存摘要、前进同步水位和插入待提醒。输入非空、同账号/文件夹/世代，两个目标水位必须相等且严格大于输入 UID。只有未读且 UID 不低于旧同步水位的邮件能进入待提醒。C3 决定输入哪些新到达邮件有通知资格；不得用于先缓存一批、随后在同一旧水位补提醒。
- 非通知导入用 `save_summaries`；已对账但无资格提醒的后续区间用 `advance_sync(account, folder, validity, N)`，或 `commit_arrivals(..., batch_id=None, ...)`。静默区间以已 ack 检查点参与推进，不能越过旧 pending。
- `pending(account, folder)` 返回按水位排序的未确认批次；成员包含稳定 MailKey，重开数据库仍保留。同 batch id/目标水位重放幂等，冲突目标水位抛 `batch_conflict` 且整个事务回滚。
- `ack(account, folder, validity, batch_id)` 幂等；后批先 ack 只记 acked，连续较早批次全部确认后才推进 notify_next。未知 batch 无操作；过期世代拒绝。已 ack 旧 UID 不会被后来新批重新提醒。
- `delete_messages(account, folder, validity, uids)` 原子删缓存与未读关联；删除/变已读会移除 pending 成员，空批次作为已确认推进，通知目标不会留指向旧正文。

Store 只提供原子数据操作；首次导入基线、n:* 过滤、补收汇总、串行同步、SSE 重放/ack HTTP 和系统通知去重仍属于 C3/E。

## Schema 与迁移

只接受文件名 mail.db。默认 SQLite 线程检查开启；工作线程调用 Store 会得到 sqlite3.ProgrammingError。单连接、WAL、busy_timeout=1000ms、foreign_keys=ON；公共写入用连接事务上下文，异常回滚，无逐条提前提交。

| 版本/表 | 内容 |
| --- | --- |
| v1 accounts | id、address；无密码 |
| v1 folder_catalog | (account_id, folder_id)、完整 MailFolder JSON；LIST 不需要 UIDVALIDITY |
| v1 folders | (account_id, folder_id)、UIDVALIDITY、sync_next、notify_next、checked_at；选择后的同步状态 |
| v1 summaries | (account_id, folder_id, uidvalidity, uid)、MailSummary JSON；复合主键支持 UID 索引分页 |
| v1 bodies | 同邮件复合键、kind、source；解码原文，外键依赖摘要 |
| v1 unseen | 整箱未读 UID 集合；不依赖摘要是否缓存 |
| v2 notification_batches | 账号/文件夹/世代/batch_id、目标 notify_next、acked |
| v2 notification_items | 批次及稳定 UID；同时外键依赖批次和摘要 |

首次 user_version=0 在一个 BEGIN IMMEDIATE/COMMIT 中建 v1/v2，最终 user_version=2；v1→v2 仅加通知表，保留摘要和配置。测试把 v2 通知表移除、版本退至 v1，重开后验证迁移和摘要保留。不改现有聊天数据库，不支持悄悄降级；未知版本关闭连接并抛 unsupported_schema。

## MIME、正文 section 与线程交接

```python
from feishu_lite.mail.mime import normalize_structure, select_body, parse_headers, decode_body
from feishu_lite.mail.html import render_body
from feishu_lite.mail.types import MailBody

# IMAP 专用工作线程；C2 使用 fetch_result[uid][b'BODYSTRUCTURE']
structure = normalize_structure(body_data)
selected = select_body(structure)
headers = parse_headers(header_fields_literal)
part = selected.body  # None 表示没有可展示正文，附件元数据仍可显示
# 只在 part 不为 None 且限额满足时 fetch BODY.PEEK[part.section]
raw = decode_body(part, selected_section_literal)

# 将 raw / headers / selected 交回事件循环；Store 写入不能放 IMAP 线程
store.save_body(key, raw)
# 缓存命中：事件循环先 detach，再交 MIME 工作线程 render_body
raw = store.get_raw_body(key)
content = render_body(raw)  # MIME 工作线程；plain 是纯文本，HTML 才净化
body = MailBody(kind=raw.kind, content=content)
```

`normalize_structure` 接受 IMAPClient 4.1.0 BodyData 的真实形式：multipart 首项必须是 list[子 BodyData]，后续为 subtype/params/disposition；singlepart 按 RFC3501 固定字段位置。**不接受未经库归一化的原始 multipart 连续 tuple。** 根 singlepart section=1，multipart 根 section 为空，子部分为 1、2、1.1 等；仅 selected.body 的数字 section 能用于正文 PEEK。related 的 start 按 content-id 找根，没有 start 才取首部分；找不到指定根不擅自换另一个正文。message/rfc822 全子树跳过，仅列附件元数据。

Header 字段只需 FROM/TO/CC/SUBJECT/DATE/MESSAGE-ID；received_at 由 C2 用 INTERNALDATE 换算 Unix 秒。附件大小为 encoded_size 与 size_is_approximate=true，multipart 未知则 None。RFC2231 续段、RFC2047 文件名、Content-Type name 回退、GB18030 扩展字符均有样本。BASE64 严格校验、quoted-printable 识别畸形转义；不为解码下载任何附件。

`parse_messages` 是已给定结构/literal 的逐封错误隔离边界，返回 ParseResult.error；它不抓取任何数据。C2/C3 可直接调用低层函数，在单封工作项的顶层 catch MailError，再保留摘要错误占位继续整批。低层不泛化捕获；标识、charset、header、structure、literal 的输入边界只归一化具体解析异常，批次只捕获 MailError。

`get_body` 是同步便利入口，每次重净化，适合非事件循环调用和测试。**C3 的异步请求应使用 get_raw_body + MIME worker render_body，不能把 Store 放工作线程，也不能直接把 RawBody.source 当 HTTP 的展示字段。** 这些基础函数尚未接 API，账号/连接世代与取消后迟到响应的业务校验留 C2/C3。

## 限额、错误类别与 HTML 政策

| 限额 | 默认值与判定 |
| --- | --- |
| 响应/结构 | 8 MiB；结构转换前迭代检查原子内容大小与嵌套；literal/批次 supplied literals 也检查。C2 仍必须在网络/库解析之前限制真实响应字节，不能靠解析后检查防分配 |
| 头部 | 256 KiB（原始 HEADER.FIELDS literal） |
| 正文 | 2 MiB；BODYSTRUCTURE 宣告编码后大小、实际 literal、transfer 解码后 bytes、UTF-8 原文大小都检查；编码后超过限制的正文也拒绝，即使最终解码可能较小 |
| MIME 深度 | 20 层 MIME 节点；忽略的转发结构另有转换前嵌套保护 |
| MIME 部分数 | 200；转换前还用 200×64 的原子数预算，限制异常参数/转发结构 |

错误为 MailError.code（str(error) 只有代码，不附原邮件）：`invalid_id`、`stale_cursor`、`stale_message`、`folder_missing`、`invalid_store_path`、`unsupported_schema`、`account_address_changed`、`invalid_page_size`、`empty_arrivals`、`invalid_watermark`、`invalid_batch`、`batch_conflict`；解析错误包括 `malformed_mime`、`malformed_encoding`、`unsupported_charset`、`unsupported_transfer_encoding`、`unsupported_body`、`response_too_large`、`headers_too_large`、`body_too_large`、`mime_too_deep`、`too_many_parts`。C3 注册 mail 域 API 错误映射，不走聊天 AuthExpired，不记录原始异常 cause/响应或 Pydantic 请求 input。

nh3 采用显式 tag/attribute allowlist：保留段落、基础字形、标题、列表和表格；彻底移除 script/style/iframe/object/embed/form/svg/math 等内容、所有事件属性、style/class/id、meta/base、资源属性、注释。图片变成带转义 alt 的文字占位；链接仅保留具有有效 host 的显式 HTTP(S) URL，拒绝其他 scheme、相对 URL、畸形 host/IPv6/端口。合法 IPv4/IPv6、localhost、单标签内网名、.local/.internal 等链接均保留供用户主动点击，不按 host 分类禁用。首版禁用所有 CSS，正文排版可能简化；不增加远程资源开关。

coordinator 审阅指出先前额外的 IP/内网链接禁用会损害工作邮件可用性，已先补 8 项运行期失败行为测试再移除。href 本身不授权自动加载：D2 负责非持久 WebKit、全网络规则在第一封加载前挂载，以及所有导航/新窗口明确用户手势后外开，本地接口和 token 防护落实在该边界。C1 继续移除一切自动资源属性，不宣称浏览器安全验收已完成。

已核对 [nh3 官方 API](https://nh3.readthedocs.io/en/latest/) 的 clean_content_tags、attribute_filter 和 url_relative 契约；文档快照 `tmp/2026-10-13-email-foundation-c1/nh3-docs.md`。context7 当前无可调用工具，按项目 fallback 用 firecrawl-scrape 获取正式文档，并检查已安装 IMAPClient 4.1.0 发布包源码。没有下载文档入 kb/refs 或扩大任务范围。

## C2/C3/D 责任与遗留问题

- **C2**：TLS、串行 daemon 线程、可中断 IDLE、建连/停止时限、真实库配合最小服务端、真实响应在库解析前的大小限制、只取 selected BODY.PEEK section、非连续 UID 的服务端分页；不能把 BODYSTRUCTURE 含附件误当正文下载。
- **C3**：同步状态机/通知资格与汇总、账号生成/移除/凭证注入、世代/取消检查、所有 mail API/SSE/错误隔离；Store 的原子操作不代替端到端生命周期。账号更换/删除要停止旧任务再清缓存，迟到结果不能创建回旧账号。
- **D1/D2**：钥匙串与重启注入、Swift 邮件模型/API 解码、阅读 UI、异步正文迟到防护、可见性已读；D2 负责 WebKit/CSP/资源规则/外开导航，后端净化样本通过不代表浏览器实际执行/加载安全已经验收。
- **E/F**：实际 badge/通知/ack/目标清理、独立隔离 UI、授权范围内真实 Seen/新信/跨端/唤醒验证；A/B 的真实未验项不因本次自动测试消失。

本次无剩余已确认 C1 缺陷。以上是既定后续阶段和有意限制，不登记为新增 known-issues；现有 known-issues 原样保留。原计划组合 C/D 检查项仍未全部勾选，只新增有证据的 C1 子项。

## 资源清理

仅测试进程和其隔离临时 SQLite/短时测试 HTTP 服务；所有 pytest 命令已退出，fixture 关闭服务和线程，MailStore fixture/重开连接均关闭。未创建真实 IMAP 连接、持久后端、App、caffeinate、browser 或 simulator，故没有需要 mac-dev-cleanup 的自建浏览器/模拟器；不运行广泛清理影响其他会话。保留 tmp 中红绿日志与文档快照，无截图。`audit_evidence.py` 已通过 uv 执行，`evidence-audit.json` 记录无 pytest/firecrawl scrape 残留、文档链接有效、App/协调文档无改动及日志 SHA256。

## 相关文档

- [协调与 C1 brief](../plans/2026-10-13-email-reader-coordination.md) — 执行范围，未修改状态。
- [原邮件计划](../plans/2026-10-13-email-reader-plan.md) — 依据并更新 C1 证据子项。
- [A IMAP 探路](../notes/2026-10-13-email-imap-probe.md) — 库选型与真实 BodyData 约定。
- [B 实现](2026-10-13-email-shell-phase-b.md)、[B 独立验收](2026-10-13-email-shell-b-acceptance.md) — 读取前序接口/验收边界，未改 App。
- [邮件缓存与安全正文](../docs/email-foundation.md) — 本次新建的当前行为说明。
