---
created: 2026-10-13
tags:
  - review
  - email
  - imap
  - architecture
---

# 邮箱阅读器计划技术审查

审查工具：通过 Herdr 启动的 Claude Code（默认配置显示 Opus 5.5 / xhigh）；agent `email-plan-review`，会话 `81956bd8-a4be-47c1-88dc-f2726e220804`。被审查版本：`aa889ee`。

需求范围已确定，本次审查只关注技术可行性、实现约定和测试覆盖，没有修改实现或原计划，也没有连接真实邮箱。以下保留 Claude 面向用户输出的审查报告；引用的计划行号对应被审查版本。

阅读说明：这些是未实现功能的设计风险，不是当前应用已发生的邮箱缺陷。“已证实”主要指现有代码或协议事实，具体后果仍取决于后续实现。修正建议是候选方案，不代表已经全部采纳。尤其同步水位与通知交付/确认水位应分开维护；通知确认失败不能阻塞邮件入库或同步进度。稳定通知 identifier 能帮助替换通知，但仍需验证是否重复发声，不能直接承诺严格 exactly-once。

## 相关文档

- [被审查的开发计划](../plans/2026-10-13-email-reader-plan.md)

## Claude Code 审查原文

我审查了 `kb/plans/2026-10-13-email-reader-plan.md`（aa889ee）。计划的大方向站得住：用 BODY.PEEK 读正文，用 UIDVALIDITY+UID 做邮件键，不靠序号，不把 Message-ID 当主键，通知按领域路由，HTML 多层隔离，`\Seen` 保存不了就明确判为失败。下面只列实质问题，共 1 个 P1、8 个 P2、5 个 P3。

本次只读：没有修改项目文件、没有提交、没有连接邮箱。只在会话临时目录跑了一个本地 FastAPI 复现脚本（结果见 P2-7）。

## P1

#### P1-1 钥匙串条目不区分后端数据目录，隔离验收会读到、覆盖甚至删除真实邮箱密码【已证实：代码与既有验收流程】
- **计划**：L107（App 存钥匙串，后端重启后由 App 重新注入）、L108（移除邮箱时删除钥匙串条目）、L204（隔离环境验证"配置缺失/错误"）、L206。
- **证据**：
  - 钥匙串按用户和签名身份全局共享，跟 `FEISHU_LITE_HOME` 无关。
  - App 支持用 `FEISHU_LITE_HOME` 换数据目录，也支持用 `FEISHU_LITE_BACKEND_URL` 直连外部后端（`FeishuChat/Services/BackendConfig.swift:14-17,39-40,49-51`）。
  - 以往验收就是用 `tmp/dev-home`、`empty-home`、`expired-home` 加 FakeSource 跑完整 App（`kb/sessions/2026-10-06-image-messages.md:34`）。
- **后果**：
  - 隔离实例一启动，就会把真实的专用密码注入测试后端，连上真实邮箱。之后打开任何邮件都会标成已读，违反 L206。
  - 在隔离实例里测"配置错误/移除账号"，会覆盖或删除真实条目。正式 App 下次就会注入错误密码，或者显示未配置。
  - 直连外部后端时，App 会把密码发给任意指定的 URL。
- **最小修正**：
  - 后端在自己的数据目录里生成并保存一个 `mail_account_id`（UUID），通过 `/mail/status` 返回。
  - 钥匙串条目的 account 用这个 id 加邮箱地址。App 只向 id 匹配的后端注入密码；外部后端模式默认不注入。
  - 先写 BDD：id 不同的后端读不到条目；删除操作只删自己那一条。

## P2

#### P2-1 `PUT /mail/account` 同时承担"配置新账号"和"重启后重新注入"，后端重启时的状态没定义全【设计缺口已证实；钥匙串弹框需实测】
- **计划**：L106、L107、L118、L188。
- **证据**：
  - 后端崩溃后由 supervisor 重启（`BackendSupervisor.swift:71-97`）。App 只能在 `.ready` 时换新 client 再注入（`AppState.swift:82-94`）。
  - L106 规定"改地址视为新账号，隔离旧缓存"，但没说同一地址重复 PUT 怎么处理。
  - 按 TN3137，data protection keychain 需要由 provisioning profile 授权的 entitlement。本项目 Debug 用 Apple Development，Release 用 Developer ID，都没有 profile，实际只能用 file-based keychain。
- **后果**：
  - 如果每次重启都按"新配置"处理，同步水位会被重置：离线期间到达的邮件被当成历史导入，不再提醒；缓存也可能被清掉。
  - 钥匙串读取只分成功、失败两种结果时，"拒绝访问""钥匙串锁定""条目不存在"都会显示成未配置。
  - Debug 和 Release 构建互相读取条目时可能弹系统授权框（推断，需实测）。后端崩溃循环时，每次重启都可能再读一次钥匙串。
- **最小修正**：
  - 拆成两个接口：`PUT /mail/account` 只做新配置，地址变了才换分区；`PUT /mail/account/credential` 只注入密码，幂等，不动水位和缓存，并校验 account_id。
  - `/mail/status` 增加 `credential_missing` 状态，界面提示"重新输入专用密码"，而不是显示配置引导。
  - App 每次启动只读一次钥匙串，之后把密码放在内存里，后端重启时直接注入。
  - 分开处理 `errSecItemNotFound`、`errSecUserCanceled`/`errSecAuthFailed` 和 `errSecInteractionNotAllowed`。

#### P2-2 Python 3.12 下的 IDLE、阻塞读的取消和关停没有落到可实现的程度【版本事实已证实；延迟需探路】
- **计划**：L39、L103-104、L139、L164。
- **证据**：
  - Release 的安装命令固定 `--python 3.12`（`BackendInstallation.swift:20`），`backend/.python-version` 也是 3.12。
  - `imaplib.IMAP4.idle()` 是 3.14 才加的，本机 3.12.12 的 imaplib 没有这个方法；`IMAP4_SSL` 默认 `timeout=None`，即读操作没有超时。
  - 可选的库：
    - aioimaplib 2.0.3：asyncio 原生，支持 IDLE，classifiers 含 3.12。
    - IMAPClient 4.1.0：同步库，提供 `idle_check(timeout)`，自带 BODYSTRUCTURE、ENVELOPE 和 modified UTF-7 的解析。
  - 3.12 的 `asyncio.run` 退出时最多等默认线程池 300 秒（`asyncio/runners.py:73`，`THREAD_JOIN_TIMEOUT=300`）；非 daemon 线程会让进程一直等下去。
  - App 退出时只等后端 2 秒（`BackendSupervisor.swift:57-67`）。
- **后果**：
  - 用同步库时，工作线程阻塞在 IDLE 等待里。用户点开邮件或提交已读，都要等这次等待超时才能发 DONE，超时取多长就是点击延迟。
  - 睡眠唤醒后 TCP 连接常常是半开的。没有读超时就会永远卡在 IDLE，既不重连也不对账。
  - 退出时阻塞线程拖住进程，旧后端可能和下次启动的新后端并存一段时间，同时写库、同时连 IMAP。
- **最小修正**：
  - 阶段 A 把"IDLE 能被打断"列为选库硬指标：
    - aioimaplib：用 `wait_server_push` 和命令队列事件一起等待，命令一来就打断。
    - IMAPClient：`idle_check` 周期不超过 1–2 秒；关停时从事件循环线程 `socket.shutdown()`，线程设为 daemon。
  - 所有命令都设读超时，并按服务器实测的超时时间定期重发 IDLE（RFC 2177 要求至少每 29 分钟一次）。
  - IDLE 期间收到的 EXISTS/EXPUNGE/FETCH 只当"需要对账"的信号，不去解释其中的序号。
  - App 已经监听 `didWakeNotification`（`AppState.swift:113-126`），唤醒时调用一次 `POST /mail/sync`，后端直接丢弃旧连接重连。
  - 用户触发的取正文和 STORE 排在后台分页前面执行。

#### P2-3 SQLite 和事件分发都不能直接跨线程用【已证实】
- **计划**：L102-105、L184。
- **证据**：
  - `Store` 只有一个连接（`check_same_thread=False`），每个方法单独提交（`store.py:56-59,69-74`）；`sqlite3.connect` 默认 `timeout=5.0`。
  - `_emit` 直接 `queue.put_nowait`（`service.py:84-86`），而 asyncio.Queue 不是线程安全的。
  - 现有的 `_every` 只在聊天在线时执行（`service.py:152-156`）。
- **后果**：
  - 邮件线程复用 `Store` 时，它的事务会和聊天写入交错。
  - 另开连接写同一个文件时，在非 WAL 模式下，聊天写库可能在事件循环上阻塞最多 5 秒，HTTP 和 SSE 全部卡住，正好违反 L103。
  - 从线程里 `put_nowait`，SSE 可能延迟或收不到事件。
  - 复用 `_every` 的话，聊天未登录时邮件也会停止同步。
- **最小修正**：
  - 邮件用单独的 `mail.db`（单独连接、WAL、busy_timeout）。
  - 写库和 emit 都只在事件循环线程上做；工作线程只负责 IMAP I/O 和 MIME 解析，结果交回事件循环。跨线程发事件用 `call_soon_threadsafe`。
  - 独立文件还有两个好处：移除账号直接删库；不用给现在没有版本号的聊天表结构做迁移。

#### P2-4 "按收件时间倒序 + UID 游标 + 100/50 分页"在没有 SORT 的 IMAP 上不一致【协议事实已证实；飞书是否支持 SORT 需探路】
- **计划**：L38、L121、L181。
- **证据**：
  - RFC 3501 §2.3.3：COPY 或 MOVE 进来的邮件保留原来的 INTERNALDATE，APPEND 进来的用指定时间，但它们的 UID 都是新分配的、更大的值。
  - UID 是稀疏的。
  - 飞书提供邮箱搬家功能（会 APPEND 历史邮件），推测迁移过的账号 UID 顺序和时间顺序差异很大。
- **后果**：
  - 按 UID 取页、按时间排序显示，第一页底部会出现很旧的邮件，加载第二页后新内容又插到它上面。
  - 用 (date, uid) 做游标、按 UID 取数会漏邮件或重复。
  - 用 `UID FETCH a:b` 按区间取，凑不出固定的 50 封。
- **最小修正（二选一，写进计划）**：
  - v1 按 UID 倒序排列（也就是进入收件箱的顺序），只显示 INTERNALDATE。分页对 `UID SEARCH ALL` 的结果切片，游标用 (uidvalidity, uid)。
  - 如果坚持按时间排序：先一次性 `UID FETCH 1:* (INTERNALDATE)` 建本地索引（支持 SORT 时用 `UID SORT (REVERSE ARRIVAL)`），之后增量维护。
  - 另外，`GET /mail/messages/{id}` 的 id 要用不透明且 URL 安全的值。现有 client 会把 id 直接拼进路径，以后文件夹名里出现 `/` 时路由会出错。

#### P2-5 没有规定用哪些命令算未读总数和对账，容易选错，代价也高【协议事实已证实】
- **计划**：L116、L134、L137、L148、L154。
- **证据**：
  - SELECT 返回的 `[UNSEEN n]` 是第一封未读邮件的序号，不是未读数量（RFC 3501 示例原文 "Message 12 is first unseen"；RFC 9051 已弃用）。
  - RFC 9051 §6.3.11：STATUS 不应对当前选中的邮箱使用，也不能用来查新邮件。
  - RFC 3501 §6.4.8：`559:*` 这样的区间，即使没有更大的 UID，也总会包含最后一封邮件。
- **后果**：
  - badge 可能显示成序号。
  - 或者每 60 秒全箱扫一次 FLAGS。按 2 万封量级估算，约每分钟 1 MB（推算）。
  - 或者因为 `n:*` 总会返回最后一封，最新那封邮件每轮都被当成新邮件重复提醒。
- **最小修正**：每轮对账固定为以下几步。
  - `UID SEARCH UNSEEN` 拿到整个收件箱的未读 UID 集合。badge 就是集合大小，同时用它修正缓存里邮件的已读状态。
  - 新邮件：用 UIDNEXT 和水位比较，再 `UID FETCH 水位+1:*`，在客户端过滤 `uid > 水位`。
  - 删除和移动：只对已缓存的 UID 做 `UID SEARCH UID <集合>`，求差。
  - 服务器支持 CONDSTORE 时再用 `CHANGEDSINCE` 优化。
  - 跨端已读"60 秒内"的验收目标和 60 秒对账周期一样长。建议把周期调到约 45 秒，或者放宽目标。

#### P2-6 `mail.arrived` 走即发即弃的 SSE：没人订阅时事件就丢了，水位却已经前进【已证实】
- **计划**：L37、L126-128、L157、L197。
- **证据**：
  - `_emit` 只发给当前的订阅者（`service.py:84-86`），`/events` 连上时只补发一个聊天 `status`（`api.py:98-113`）。
  - App 的 SSE 断线后按 1/2/5 秒退避重连（`AppState.swift:137-158`）。
  - 计划没规定 App 在 SSE 连上之前还是之后注入密码。
- **后果**：
  - 后端首次同步产生的补收汇总，或者在 SSE 重连间隙里到达的邮件，提醒会永久丢失，违反 L37 和 L157。
  - "稳定在线"和"长时间离线"没有界线，L197 的测试写不出确定的期望。
- **最小修正**：
  - 后端维护一个待提醒队列。App 确认（ack）后，水位才前进。
  - `/mail/status` 快照里带上待提醒的邮件，App 每次 SSE 连上后先拉一次。
  - App 先连上 SSE，再注入密码。
  - 把汇总规则定成可测的，例如"一次发现超过 3 封，或最早一封比发现时间早 10 分钟以上，就合成一条汇总"。
  - 通知 identifier 用稳定的邮件键，重复投递时只会覆盖，不会新增。

#### P2-7 FastAPI 默认的 422 响应会回显密码，App 会把它写进日志和界面【已证实，本地复现】
- **计划**：L107（不放日志）、L117-118。
- **证据**：
  - 用后端 venv 里当前版本的 FastAPI 做了最小复现：PUT 请求缺一个字段时，返回 `{"detail":[{"type":"missing",…,"input":{"address":"a@b.c","password":"S3CRET-app-pass"}}]}`。
  - `BackendClient.check` 把响应体前 200 字节放进错误（`BackendClient.swift:146-148`）。现有代码会以 `privacy: .public` 记录这类错误并显示到界面（`Conversation.swift:137-138`、`LoginModel.swift:72-74`）。
  - README:32 要求升级 App 时手动重装后端，所以 App 和后端模型不一致是现实场景。
- **最小修正**：
  - 给 `/mail/account*` 注册一个不回显 `input` 的 `RequestValidationError` handler，密码字段用 `SecretStr`。
  - 加测试：错误请求的响应和日志里都不含密码。

#### P2-8 模块切换如果做成"隐藏保活"，聊天输入框可能还占着焦点，在邮件页按回车会把聊天草稿发出去【推断，需在阶段 B 验证】
- **计划**：L71、L175。
- **证据**：
  - 输入框一创建就抢第一响应者（`ComposerView.swift:99-102`），回车直接发送（`:130-140`）。
  - 消息列表靠 `.defaultScrollAnchor(.bottom)` 和视图里的 `@State isAtBottom` 维持滚动位置（`ConversationView.swift:36,50-55`），视图一重建位置就丢。这会诱导实现者把两个工作区都保留在视图层级里，只是隐藏。
- **后果**：隐藏后的 NSTextView 会不会交出焦点，取决于 SwiftUI 怎么映射"隐藏"，目前没验证。如果不交出，在 Email 页打字或按回车可能给真实工作群发出消息。
- **最小修正（二选一）**：
  - 切换时重建视图，把滚动锚点存进模型，切回来再恢复。
  - 保活时显式 `makeFirstResponder(nil)`，隐藏的那一侧禁止交互和键盘焦点。
  - 两种做法都在阶段 B 加一条验收：在 Email 页按回车或打字，聊天不发送，草稿不变。

## P3

#### P3-1 已读只有"正文加载成功"一个触发点【已证实】
- **计划**：L144、L150、L192。
- **对照**：聊天在 App 激活和窗口成为 key 时会重新判断要不要标已读（`AppState.swift:96-110`）。
- **后果**：
  - 选中一封未读邮件后切到别的 App，再切回来，邮件不会标已读。
  - 从 Email 切回 Messages 时，期间到达的聊天消息也不会标已读。
- **修正**：把"切换模块、App 激活、窗口成为 key、正文加载完成"都作为两个模块的已读触发点。在 Core 里放一个 `ViewingContext(activeModule:isAppActive:isWindowVisible:selection:)`，两个模块共用。

#### P3-2 App 把所有 409 都当成聊天登出【已证实】
- **证据**：
  - `BackendClient.swift:143-145` 把所有 409 映射成 `.loggedOut`，`Conversation.swift:135` 会静默吞掉这个错误。
  - 后端的全局 `AuthExpired` handler 会让聊天登出（`api.py:41-44`）。计划 L128 只约束了这一侧。
- **后果**：邮件接口用 409 表示"账号已切换""世代过期"等冲突（这是 409 的常规用法）时，App 会当成飞书登录失效，错误被吞掉或显示成"登录已失效"。
- **修正**：邮件错误统一用 `{domain:"mail", code}` 加非 409 的状态码；IMAP 认证失败用的异常类型不继承 `AuthExpired`；App 只有在 `detail=="logged_out"` 时才映射为聊天登出。

#### P3-3 新版 App 配旧版后端时没有提示【已证实】
- **证据**：README:32 要求升级 App 时手动重装后端；`/status` 里没有版本或能力字段（`types.py:52-55`）。
- **后果**：`/mail/*` 返回 404，Email 页看起来像普通的连接失败。
- **修正**：`/status` 增加 `api_version` 或 `features`。App 发现后端没有 mail 能力时，显示重装后端的命令（复用现有的安装引导）。

#### P3-4 没有中文编码和正文 part 的选择规则【需脱敏样本验证】
- **计划**：L69 只提到文件夹名；L72-74、L136 没有编码规则。
- **常见情形**：
  - 邮件头用 RFC 2047 编码，或者直接是未声明编码的 GBK 字节。
  - 声明为 `gb2312` 的内容，实际是 GBK/GB18030 字符。
  - 附件名用 RFC 2231 编码（`filename*=`）。
  - 被转发的 `message/rfc822` 里的文本 part 被误当成正文。
- **修正**：
  - 邮件头取 `BODY.PEEK[HEADER.FIELDS (...)]`，交给 `email` 包解析，失败时依次按 utf-8、gb18030 兜底。
  - gb2312 和 gbk 一律按 gb18030 解码。
  - 正文只在顶层的 alternative/related 结构里选（HTML 优先，没有就用纯文本），跳过附件和 rfc822 的子树。
  - 阶段 C 的样本要覆盖上面这些情形。

#### P3-5 部分测试按计划写不出来
- **阶段 B**（L175）：要测的是 AppState 的编排逻辑，但 AppState 在 app target 里，依赖 NSApp；工程只有 FeishuChatCore 的单元测试，没有 app 测试 target。计划要写明哪些类型抽到 Core（ViewingContext、通知路由的编解码、未读汇总），草稿和滚动位置的保留只能靠 UI 验收。
- **阶段 C**（L181）：fake 的 IMAP 适配器会把风险最大的部分一起 fake 掉：IDLE/DONE 调度、超时、半开连接、`n:*`、字面量解析。建议写一个最小的脚本化 IMAP 服务端，可以注入延迟、断线、IDLE 期间的 EXPUNGE，用真实适配器去跑这些测试。

## 剩余验证点（建议并入阶段 A/D）
- **探路方式**：用 EXAMINE 只读打开邮箱；只对指定的测试邮件 SELECT 再 STORE。
- **CAPABILITY**：IDLE、CONDSTORE/QRESYNC、ESEARCH、SORT、SPECIAL-USE、UTF8=ACCEPT；是否要求先发 ID 命令（部分国内邮箱要求，飞书情况未知）。
- **SELECT 返回内容**：PERMANENTFLAGS 是否包含 `\Seen`；有没有 `[READ-ONLY]`；是否返回 UIDNEXT。
- **IDLE 行为**：期间是否推送其他端的已读变化；服务器多久断开 IDLE；同一账号允许几个并发连接。
- **认证失败**：错误密码重试会不会触发限流或锁号。
- **钥匙串**：Debug 和 Release 构建读写同一条目时是否弹框。
- **HTML**：
  - 拦截远程资源的规则表要在第一次加载前编译好并挂上，否则第一封邮件的远程图片可能照常加载。
  - `target=_blank` 链接要在 `createWebViewWith` 里改为外部打开。
  - 使用 `nonPersistent` 数据存储。
  - 确定 HTML 净化放在后端还是 App。
  - HTML 这部分整体设计没有发现重大问题，以上是需要实测的细节。
- **新邮件测试**：需要用户指定一个发件来源，或者确认飞书里自己发给自己的邮件会进收件箱。

要的话，我可以把这份 review 存到 `kb/reviews/`。
