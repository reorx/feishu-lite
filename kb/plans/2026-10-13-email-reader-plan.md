---
created: 2026-10-13
tags:
  - plan
  - email
  - imap
  - swiftui
  - python
---

# Messages / Email 应用框架与飞书邮箱阅读器

本计划供分阶段开发执行：在现有 FeishuChat 中增加 Email 模块，让聊天和邮件独立同步、共用窗口框架，并汇总未读 badge。阶段 A 只读探路、B 外壳及 C–E 自动实现已完成；B 隔离 UI 的切换核心行为已验证，F1 已验证主要配置/阅读器与实际 WebKit 隔离，R1屏幕滚动与新增scheme隔离已通过F1b独立复验，浅色/拖宽/cursor恢复/fake凭证错误UI已补齐，纯文本R2滚动及原生视图主要行为已通过F1c独立复验、P2关闭；真实中文组字及少量UI/精确竞态仍未验；F2a主要真实系统通知/点击/跨进程ack去重/清理/Dock已验，未知提示布局P2已由F2b独立屏幕复验关闭；真实测试UUID自身SecItem/凭证恢复调用、隔离生产Supervisor及全量通过，跨签名互访被login密码授权阻塞；合成唤醒/聊天不代替机器睡眠或真实邮箱，取消隐藏/扫码及邮箱错误期间聊天等仍未验，准确范围见F2a/F2b报告。

## 1. 已定范围与实施默认值

### 用户已确认

- 最左侧增加固定窄导航栏，提供 Messages、Email 两个入口及各自未读 badge；右侧按模块显示列表与详情。
- 邮箱是飞书原生邮箱，可以生成第三方客户端专用密码。使用 IMAP 收信，本期不实现 SMTP、发送或回复。
- 首版列出服务端返回的全部文件夹，但只同步、读取收件箱。其他文件夹的读取和切换放到下一版。
- 文件夹入口位于邮件列表列顶部，通过下拉菜单展示；不增加单独的文件夹布局列。
- 沿用 Python 后端联网与 SQLite 缓存、SwiftUI 展示的架构。
- 打开邮件后同步服务端已读状态；IMAP 支持此行为，具体账号权限在接入验证时确认。
- 附件只展示基本信息，不下载、不预览附件。
- Dock badge 汇总聊天与邮件未读。

### 计划采用的默认值

以下是实施选择，不冒充用户逐项确认；若实际验证需要调整，在开发 session 说明原因。

- 单邮箱账号；与聊天扫码账号独立配置、独立登出。退出聊天不删除邮箱，移除邮箱不退出聊天。配置页明确提示两者独立，切换聊天账号不会自动切换邮箱。
- 邮件逐封列出，不做邮件串聚合；首版不做搜索、星标、删除、移动、规则编辑或手动标未读。
- 支持纯文本和 HTML 正文；HTML 禁止脚本、表单、自动导航及远程资源加载。链接由用户点击后在外部浏览器打开。
- Messages badge 保持现有规则：未读消息条数之和，免打扰不计，隐藏聊天仍计入；Email badge 仅计算整个收件箱的未读邮件数，不只统计当前加载页。
- badge 为 0 时不显示，超过 99 显示 `99+`；内部保留真实计数。系统通知开关不改变 badge 统计。
- 首次导入只更新列表与 badge，不对历史邮件弹通知；稳定运行中的新增未读邮件才逐封提醒。任何一次同步发现的新未读超过 3 封，或其中最早一封的收件时间比发现时早 10 分钟以上（App 重启、睡眠唤醒、长时间断线后的补收），合成一条汇总提醒，避免恢复后大量弹窗。
- 初始加载最近 100 封邮件摘要，向下每次加载 50 封；正文按需获取并缓存，不全量下载邮箱。列表按邮件进入收件箱的先后（UID）倒序，行内显示服务端收件时间。原因：没有 SORT 扩展时按收件时间分页会漏邮件或重复；被移动、迁移进收件箱的旧邮件收件时间早但 UID 新，会排在较新的邮件之上，这是接受的取舍。
- 优先使用服务器支持的 IDLE；不支持时每 60 秒检查新邮件。无论是否使用 IDLE，都每 45 秒对账收件箱未读状态，使其他端已读能在 60 秒的验收目标内同步；参数可在真实验证后调整并记录。
- 两个模块在切换后仍保持同步；主窗口关闭后沿用现有常驻方式，退出 App 才停止后端任务。

## 2. 接入依据与前置验证

飞书官方配置为 `imap.feishu.cn:993`，SSL/TLS，邮箱地址加第三方客户端专用密码。管理员必须允许第三方客户端登录；官方文档注明专用密码在飞书桌面客户端生成。用户已确认具备生成条件，但本次没有索取密码、连接真实邮箱或修改邮件状态。

IMAP 的 `\Seen` 标志表示已读；使用 UID STORE 添加该标志即可同步已读。获取正文使用 BODY.PEEK，避免后台抓取隐式标已读。协议支持不等于实际账号验证通过，实施第一阶段检查读写权限及持久化标志。

参考：

- [飞书：在第三方邮箱客户端登录飞书邮箱](https://www.feishu.cn/hc/zh-CN/articles/902478147400)
- [IMAP：消息 UID 与 UIDVALIDITY](https://www.rfc-editor.org/rfc/rfc9051.html#section-2.3.1.1)
- [IMAP：消息标志](https://www.rfc-editor.org/rfc/rfc9051.html#section-2.3.2)
- [IMAP：LIST 文件夹](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.3.9)
- [IMAP：STATUS 不用于当前选中的邮箱](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.3.11)
- [IMAP：FETCH 与 BODY.PEEK](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.4.5)
- [IMAP：STORE](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.4.6)
- [IMAP4rev1：收件时间、SELECT 的 UNSEEN 含义、UID `n:*` 区间](https://www.rfc-editor.org/rfc/rfc3501)（§2.3.3、§6.3.1、§6.4.8）
- [IMAP IDLE（RFC 2177）](https://www.rfc-editor.org/rfc/rfc2177)
- [Python imaplib（`idle()` 自 3.14 起）](https://docs.python.org/3/library/imaplib.html)
- [Apple TN3137：Mac 上的两种钥匙串](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

RFC 9051 用于说明协议语义，不要求飞书支持 IMAP4rev2；客户端需兼容服务器实际公布的 IMAP4rev1 与扩展。IDLE、UTF-8、CONDSTORE/QRESYNC、SORT、ESEARCH 等必须经 CAPABILITY 验证，不预设支持。

## 3. 界面与交互

```text
固定窄导航        当前模块的列表列              详情列
Messages [12]     会话列表                      聊天记录 / 输入框
Email     [3]     [收件箱 ▾]  [刷新]            邮件头 / 正文 / 附件信息
                  发件人、主题、时间、未读
```

- 应用外壳固定导航；右侧继续采用双栏分割布局。复用尺寸约定、分隔线、badge、空状态、加载/失败提示等基础组件；聊天行、邮件行及正文保持独立。
- 文件夹下拉显示全部 LIST 结果，保留层级关系和真实标识，正确解码中文名称。收件箱可用，其他文件夹禁用并注明“暂不支持读取”；不可选择的层级节点也不能触发读取。首版不展示未同步文件夹的虚假未读数。
- 不按本地化名称猜测收件箱；使用 IMAP 的 INBOX 语义。未支持文件夹的限制同时落实在后端，不能只靠 UI 禁用。
- 切换模块保留各自选中项、列表和详情的滚动位置（回到切换前首个可见的条目）、聊天草稿；保存当前模块供重启恢复。不得因视图重建丢失聊天草稿或重复启动同步。停留在 Email 时打字或按回车不得进入聊天输入框。
- 邮件列表包含发件人、主题、收件时间、未读标识和附件指示；无主题/姓名时有回退值。摘要不以全量下载附件或正文为代价。
- 详情展示主题、发件人、收件人、抄送、时间、正文。附件显示文件名、媒体类型及可得的大小；BODYSTRUCTURE 返回编码后大小时显示为约数或省略大小，不冒充解码后的精确字节数。
- 不抓取附件内容；首版 CID 内嵌图片显示占位，保留正文文本。远程图片不自动加载，首版不增加加载远程图片的开关。
- 邮箱未配置时，Email 详情区显示配置引导；配置页提供邮箱地址、专用密码、测试连接、保存、修改凭证、移除账号。飞书主机与端口预设，不扩展成通用邮箱服务配置工具。
- 已配置但钥匙串里找不到密码时，提示重新输入专用密码，不显示成未配置；钥匙串拒绝访问或被锁定时，提示授权并可重试。
- 断线时显示缓存和最后同步时间；未缓存正文显示可重试的离线提示。失效凭证与普通断网分开提示，凭证失效后停止重试，直到用户修改凭证。
- 后端版本过旧、没有邮箱功能时，Email 区显示重新安装后端的命令，不显示成连接失败。
- 聊天未登录或凭证失效时，扫码页只占 Messages 工作区，不遮挡 Email；停留 Email 时不主动开启二维码登录流程。

## 4. 架构改造

### App

当前 `Model/AppState.swift` 同时处理后端生命周期、聊天登录、会话、通知和 badge；`UI/RootView.swift` 用聊天登录状态控制整个窗口。此次按责任拆分：

```text
AppState：模块选择、后端连接、全局时间、未读汇总、通知路由、邮箱凭证注入
  ├─ MessagesState：扫码、会话列表、隐藏偏好、当前聊天、草稿、滚动锚点
  └─ MailState：邮箱配置与凭证状态、文件夹、邮件列表、当前邮件、同步状态、滚动锚点

RootView → 应用外壳 → 窄导航 + MessagesWorkspace / MailWorkspace
```

- `BackendSupervisor`、单例窗口与现有 bundle ID 保留；后端依赖缺失仍可显示全局启动引导。
- 统一维护一条 SSE 连接，按领域分发事件。每次连上后独立刷新两个模块，不受聊天是否登录限制；连上之后才注入邮箱凭证，并处理 `/mail/status` 里的待提醒列表（见 §5 通知）。
- 模块切换时重建工作区视图，不做隐藏保活。列表与详情的首个可见条目存进各自状态，切回时滚动到该条目；聊天草稿继续由 `Conversation.draft` 和 `AppState` 的 `drafts` 持有。原因：`ComposerView` 创建时会抢第一响应者、回车直接发送，保活时隐藏的输入框可能仍持有焦点，在 Email 页按回车会把草稿发进聊天；隐藏的 `ConversationView` 的 `navigationTitle` 也可能继续作用于窗口。
- 通知目标改为类型化路由：聊天 ID，或邮箱账号/文件夹/邮件标识。通知 ID 与 thread ID 加领域命名空间，防止碰撞及误清除。
- AppState 汇总两个可观察的未读计数，唯一调用 `setBadge`；移除聊天状态直接覆盖 Dock badge 的旧路径。
- `FeishuChatCore` 保持纯逻辑，至少包含：`ViewingContext`（当前模块、App 是否激活、窗口是否可见、两个模块各自的选中项；聊天和邮件的已读判断与通知抑制都由它给出）、通知路由的 userInfo 编解码、两模块未读汇总及 `99+`、邮件模型与编解码。钥匙串与 WebKit 放 app target。
- 邮箱凭证：
  - 用 file-based keychain（`SecItem` 不设 `kSecUseDataProtectionKeychain`）。原因：data protection keychain 需要由 provisioning profile 授权的 entitlement（TN3137），本项目 Debug 与 Release 签名都没有 profile。
  - 条目按后端返回的 `mail_account_id` 存取，邮箱地址作为附加属性。
  - App 每次启动只读一次钥匙串，之后把密码留在内存；后端每次重启进入 `.ready` 且 SSE 连上后，用只注入密码的接口恢复。避免后端崩溃重启时反复访问钥匙串。
  - 直连外部后端（`FEISHU_LITE_BACKEND_URL`）时不自动注入，需要时在配置页手动输入。
  - 区分“没有条目”“用户拒绝或认证失败”“钥匙串锁定”三种结果，分别对应 §3 的提示；不回落明文存储。
- `BackendClient` 只在响应 `detail` 为 `logged_out` 时把 409 映射为 `.loggedOut`。原因：现在所有 409 都被当成聊天登出，而 `Conversation` 会静默吞掉这个错误。
- 后端 `/status` 的 `features` 不含 `mail` 时，Email 区显示重新安装后端的命令，复用启动页的命令展示；`BackendStatus` 对旧后端缺失该字段要能解码。
- 不建立通用“聊天/邮件消息”模型或插件框架；仅提取实际共用的视觉组件与基础服务。

### 后端

- 保留现有聊天 Service/Source，新增独立 `mail/` 领域（IMAP 适配、业务同步、存储和 MIME 解析）。共享进程、HTTP 鉴权和 SSE 事件分发。
- 两个服务由应用生命周期协调启动和停止，任务故障隔离；邮箱网络等待、MIME 解析不能阻塞聊天事件循环。邮件的周期任务自建，不复用 `Service._every`，因为它只在聊天在线时执行。

#### IMAP 执行模型

- IMAP 库必须在 Python 3.12 下支持可被打断的 IDLE。stdlib `imaplib` 的 `idle()` 3.14 才有，而 Release 安装命令固定 `--python 3.12`，不手写 IDLE。候选：
  - aioimaplib：asyncio 原生，同时等待服务器推送和命令队列事件，有命令就退出 IDLE。
  - IMAPClient：同步库，自带 BODYSTRUCTURE/ENVELOPE 与 modified UTF-7 解析；放在专用 daemon 线程，`idle_check` 每次最多等 1 秒，期间检查命令队列和停止标志。
  - 阶段 A 按“IDLE 中的取正文请求能在 2 秒内开始执行”和探路结果选定，不预先锁定。
- 同一 IMAP 连接上的命令串行执行；需要 FETCH/STORE 时发 DONE 退出 IDLE，完成后恢复。用户触发的取正文和 STORE 排在后台分页、对账之前。
- 所有连接、命令和读取都设超时，避免睡眠唤醒后卡在半开的连接上。IDLE 至少每 29 分钟重发一次（RFC 2177），实际周期按飞书断开 IDLE 的时间调小。IDLE 中收到的 EXISTS/EXPUNGE/FETCH 只作为“需要对账”的信号，不解释其中的序号。
- 关停：lifespan 停止后 2 秒内结束邮件任务（App 退出只等 2 秒）。同步库线程设为 daemon，并从事件循环线程 `socket.shutdown()` 打断阻塞读。原因：`asyncio.run` 退出时最多等默认线程池 300 秒，非 daemon 线程会无限期拖住进程，旧后端可能与下次启动的新后端并存。
- 唤醒：后端感知不到系统睡眠。App 在 `NSWorkspace.didWakeNotification` 时调用 `POST /mail/sync?reconnect=true`，后端丢弃旧连接、重连并对账。

#### 存储

- 邮件缓存放独立的 `mail.db`（与 `cache.db` 同目录），单独连接、WAL、`busy_timeout`，用 `PRAGMA user_version` 管理迁移；不改写或清空聊天的 `cache.db`。
- 所有 SQLite 写入和 SSE emit 都在事件循环线程执行；工作线程只做 IMAP I/O 和 MIME 解析，结果交回事件循环，跨线程发事件走 `loop.call_soon_threadsafe`。原因：现有 `Store` 共用一个连接、逐条提交，跨线程会让事务交错；另开连接写同一文件时，聊天写入可能在事件循环上等锁最多 5 秒；`Service._emit` 的 `put_nowait` 不是线程安全的。
- 表按 `mail_account_id` 分区。邮件稳定标识使用账号、文件夹、UIDVALIDITY、UID；不使用会变动的序号，不把 Message-ID 当作数据库唯一键。对外的邮件 id 是这四项的 base64url 编码，可直接放进 URL 路径（以后文件夹名含 `/` 也不破坏路由），后端据此校验账号与 UIDVALIDITY 是否过期。

#### 账号与凭证

- 邮箱账号配置、连接状态和聊天身份分离。后端配置账号时生成 `mail_account_id`（UUID），与地址一起保存在数据目录。修改邮箱地址视为新账号，生成新 id；切换时撤销旧任务、丢弃迟到响应、隔离旧缓存与通知。
- 邮箱专用密码由 App 存 macOS 钥匙串，条目按 `mail_account_id` 区分，仅经现有鉴权本地接口传给后端内存；不放 UserDefaults、SQLite、命令行参数或日志。原因：钥匙串对同一用户全局可见，不随 `FEISHU_LITE_HOME` 隔离；按 id 区分后，隔离数据目录的测试实例读不到、也覆盖不了、删不掉真实条目。复制真实数据目录做测试时要去掉其中的邮箱配置。
- 后端重启后账号处于 `credential_missing`，由 App 通过只注入密码的接口恢复，不重置同步水位和缓存。钥匙串不可用时显示配置错误，不回落明文存储。
- `/mail/account*` 的请求校验错误不回显请求体：注册不带 `input` 的 `RequestValidationError` 处理，密码字段用 `SecretStr`。原因：FastAPI 默认的 422 会把整个请求体（含密码）放进 `input`，App 会把响应前 200 字节写进错误信息和日志。
- 邮箱认证失败用独立的异常类型，不继承 `AuthExpired`（其全局 handler 会让聊天登出）；邮件接口的错误返回 `{domain: "mail", code}`，不使用 409。认证失败进入 `auth_failed` 后停止重试，直到凭证被修改；普通断网按退避重连。
- 移除邮箱时停止同步，删除该 `mail_account_id` 的钥匙串条目、配置、本地邮件缓存及已递送邮箱通知，并清零邮箱 badge。普通断网/凭证失效保留缓存，不冒充已读清零。
- `/status` 增加 `features`（含 `mail`），供 App 识别没有邮箱功能的旧后端；现有字段不变。

### 本地接口约定

接口名为实施草案；模型和 Swift 解码必须同步更新，已有聊天接口保持兼容。

| 接口/事件 | 职责 |
|---|---|
| `GET /status` | 现有字段不变，新增 `features` |
| `GET /mail/status` | `mail_account_id`、地址、状态（`unconfigured` / `credential_missing` / `connecting` / `online` / `offline` / `auth_failed`）、最后同步时间、收件箱未读数及是否过期、待提醒列表 |
| `POST /mail/account/test` | 不保存配置的连接验证，返回脱敏失败原因 |
| `PUT /mail/account` | 首次配置或更换地址：生成新的 `mail_account_id`，注入密码并开始首次导入；旧账号的任务和缓存一并清理 |
| `PUT /mail/account/credential` | 按 `mail_account_id` 注入或更新密码；幂等，不重置同步水位和缓存；id 不匹配时拒绝 |
| `DELETE /mail/account` | 停止同步并清理账号缓存；App 同时删除该 id 的钥匙串条目 |
| `GET /mail/folders` | 全部文件夹标识、名称、层级、selectable 与本期 supported 状态 |
| `GET /mail/messages` | 按文件夹和不透明游标（UIDVALIDITY + UID）读取摘要；首版仅允许 INBOX |
| `GET /mail/messages/{id}` | 按需正文与附件元数据；没有已读副作用 |
| `POST /mail/messages/{id}/read` | 幂等提交已读；失败不伪报成功 |
| `POST /mail/sync` | 手动触发对账，与进行中的同步合并；`reconnect=true` 时先丢弃当前连接 |
| `POST /mail/notifications/ack` | App 处理完待提醒的邮件或汇总后确认，后端据此推进通知水位 |
| `mail.status` / `mail.updated` | 状态、摘要/标志/删除变化（带新变为已读的邮件 id，供 App 清理通知），驱动重新取数据 |
| `mail.arrived` | 有资格通知的新到达邮件或补收汇总，同时记入待提醒列表；不由普通分页/回填触发 |

SSE 订阅本身不回放旧事件；App 每次连上 SSE 后取 `/mail/status` 快照，纠正列表与 badge，并处理其中的待提醒列表。账号、同步世代和邮件标识贯穿请求/事件，旧账号或旧 UIDVALIDITY 的响应不能覆盖当前状态。邮箱异常不能走聊天 `AuthExpired` 的登出处理，App 也不能把邮件接口的错误当成聊天登出。

## 5. 同步、已读与通知规则

### 同步

1. 首次连接列出文件夹，确定 INBOX。SELECT INBOX 记下 UIDVALIDITY 与 UIDNEXT，以 UIDNEXT 作为同步基线和通知水位；用 `UID SEARCH UNSEEN` 取整箱未读，用 `UID SEARCH ALL`（支持 ESEARCH 时用其精简形式）取 UID 列表，抓最近一页摘要。
2. UID 小于基线的邮件属于历史导入；不小于基线的进入增量同步，避免初始化期间新邮件被遗漏或重复通知。
3. 摘要抓 FLAGS、INTERNALDATE、RFC822.SIZE、BODYSTRUCTURE 和 `BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)]`。正文通过 BODYSTRUCTURE 识别文本部分并用 BODY.PEEK 按需取回；不直接 FETCH 整封 RFC822 导致附件被一并下载。分页对 UID 列表切片，不按 UID 算术区间取数，因为 UID 不连续。
4. 每轮对账（IDLE 信号、45 秒周期、重连、手动刷新）固定为：
   - `UID SEARCH UNSEEN` 得到整箱未读 UID 集合。Email badge 取集合大小，同时修正缓存邮件的已读状态，覆盖其他端已读或把旧邮件标未读。
   - 新邮件：`UID SEARCH UID <水位>:*`，丢弃小于水位的结果，再抓剩余 UID 的摘要。`n:*` 在没有新邮件时也会返回最后一封（RFC 3501 §6.4.8），不过滤就会把最新邮件反复当成新邮件。
   - 删除/移动：只对已缓存的 UID 执行 `UID SEARCH UID <集合>` 求差。
   - 服务器支持 CONDSTORE 时用 `CHANGEDSINCE` 减少传输。
   - 不把 SELECT 的 `[UNSEEN n]` 当未读数（它是第一封未读的序号），不对选中的邮箱执行 STATUS，不每轮 `UID FETCH 1:* (FLAGS)` 扫全箱。
5. UIDVALIDITY 变化时使旧游标、正文关联和通知目标失效，重建该文件夹索引，水位重置为新的 UIDNEXT。重建按历史导入处理，不把整箱邮件当作新邮件。
6. 断线/睡眠恢复后重连并对账（App 唤醒时主动要求重连），缓存列表和上次已知计数继续可见，提示数据尚未同步；后台任务不会随模块切换重新创建。
7. 对正文、响应及 MIME 嵌套设置合理大小/深度上限；超限或畸形邮件提供错误占位，不能阻塞其他邮件或聊天。具体阈值随实现和测试记录。
8. 编码与正文选择：
   - 头部交给 Python `email` 包解析 RFC 2047；未声明编码的 8-bit 头部依次按 UTF-8、GB18030 解码；声明为 gb2312/gbk 的内容一律按 gb18030 解码。
   - 附件名支持 RFC 2231（`filename*=`）和常见的 RFC 2047 编码。
   - 正文只在顶层结构中选：multipart/alternative 优先 HTML、没有再用纯文本，multipart/related 取根部分；跳过 disposition 为 attachment 的部分和 message/rfc822 的整个子树，转发的邮件不当正文。

### 已读

- 只有 App 激活、主窗口实际可见、当前模块为 Email、该封正文加载成功且仍被选中，才调用已读接口。
- 切换模块、App 激活、窗口成为 key、正文或消息加载完成时，都对两个模块各判断一次已读，条件统一由 `ViewingContext` 给出。原因：聊天已在 App 激活和窗口成为 key 时补判（`AppState.observeUserReturning`）；邮件如果只在正文加载后判断，选中后切走再切回 App 的那封邮件不会标已读。
- 列表加载、预取、后台刷新、失败正文和切换后迟到的请求都不标已读。
- 使用 `UID STORE <uid> +FLAGS.SILENT (\Seen)`，保留其他 flags。操作成功后更新本地状态并对账收件箱总数；失败保留未读，显示同步失败与重试入口。
- 离线不持久化待写队列；可读缓存正文，但不宣称已同步已读。恢复在线且仍满足可见条件时重试。
- 在飞书官方端读取邮件，本端下次对账同步 badge；线上正常情况下以 60 秒内为验收目标。
- 若实际权限不允许持久化 `\Seen`，明确报告验证失败，不静默降级成本地已读并宣称功能完成。
- 聊天的“正在查看”条件同步加入 `activeModule == Messages`，防止看邮件时旧聊天选择触发已读和通知抑制；切回 Messages 时，选中会话若有未读，补一次已读。

### 通知与 badge

- Email badge 只来自整个 INBOX 的服务端未读状态；不把其他文件夹的数算进来，也不把重复 SSE 事件当增量直接累加。
- 正常在线的新到达未读邮件通知显示发件人、主题；首版不为了通知下载正文。邮箱模块在前台时，其他新邮件仍提醒；仅实际正在阅读的同一封邮件抑制提醒。
- 首次导入、加载历史页、UIDVALIDITY 重建、标志对账不触发新邮件通知。其他端把旧邮件标未读，只改变 badge。
- 通知水位与待提醒列表保存在 `mail.db`。后端把有资格提醒的邮件记入待提醒列表并发出 `mail.arrived`；App 发出通知或按规则抑制后调用 ack，后端这时才推进水位、移出列表。原因：SSE 只投给当前订阅者，后端刚启动或 App 重连间隙里发出的事件会丢失，若发出即推进水位，这些邮件就永远不会提醒。
- 一次同步发现的新未读超过 3 封，或其中最早一封的收件时间比发现时早 10 分钟以上时，合成一条汇总通知，跳到收件箱；否则逐封提醒。通知 identifier 用稳定的邮件键或汇总批次键，重复投递只覆盖、不新增。重复事件、网络重连和 App 重启不能反复提醒同一邮件。
- 点击单封通知先打开窗口、切换 Email，再加载目标；目标已移动/删除或账号已移除时给出提示并回到可用列表，不错误打开另一封邮件。
- 本端或其他端读过的邮件，其已递送通知同步清理；聊天通知清理不能删除邮箱通知。
- 不额外套用聊天“本人消息不通知”规则到邮箱：自己发给自己但实际进入收件箱的邮件仍按普通收件处理。

## 6. 实施顺序与行为测试

每阶段先写可观察行为的测试，再实现数据与逻辑；UI 无需强行为静态布局写 BDD，但模块切换、可见性与路由属于逻辑，必须测试。Bug 修复先写复现测试。依赖通过 `uv add` 管理；IMAP 库按 §4「IMAP 执行模型」的要求和阶段 A 探路结果选定，不预先锁定。

### 阶段 A：IMAP 接入探路

- [x] 在 `tmp/<date>-email-imap/` 写可复用探路脚本，使用 uv 执行；凭证通过安全输入或后续配置 UI 提供，不要求用户在聊天中粘贴密码。
- [x] 探路用 EXAMINE 只读打开收件箱；只对用户指定的测试邮件执行 SELECT 和 STORE。此次没有指定邮件，真实邮箱未执行 SELECT/STORE。
- [x] 验证 TLS、认证、CAPABILITY（IDLE、CONDSTORE/QRESYNC、ESEARCH、SORT、SPECIAL-USE、UTF8=ACCEPT、ID）及是否要求先发 ID 命令、LIST 中文/层级名称、INBOX、UIDVALIDITY、UIDNEXT、PERMANENTFLAGS 是否含 `\Seen`、是否只读、FLAGS、BODYSTRUCTURE、PEEK。
- [x] 在 Python 3.12 下实测候选库的 IDLE 在 2 秒内被打断，据此选定 IMAPClient 4.1.0；真实短时 IDLE/DONE/PEEK 与隔离串行、阻塞关停、独立进程退出均有证据。
- [ ] 真实验证 IDLE：其他端已读是否推送标志变化、服务器多久断开 IDLE；并发连接上限未做压力探测，不凭本次串行连接推断。
- [ ] 记录真实认证失败的脱敏原因。错误密码重试、限流或锁号阈值未测；阶段 A 不制造错误密码。
- [x] 初始探路不写真实邮件状态；已读验证仅针对用户指定的测试邮件。当前只有聊天测试群 litetest 获得发送授权，不能因此推定可向任意邮箱发测试邮件。新邮件通知的测试需要用户指定发件来源，或确认飞书里自己发给自己的邮件会进收件箱。
- [ ] 用测试邮件验证 `\Seen` 在官方客户端可见且重新连接后保留；记录脱敏结果。若缺凭证或测试邮件，记录真实验证待办，不阻止隔离实现和测试，也不宣称真实接入通过。

阶段 A 的只读探路与选型关卡已满足，未勾选项目仍待真实条件验证，不影响协调文档允许的隔离开发。证据、计时边界和后续注意点见 [IMAP 探路笔记](../notes/2026-10-13-email-imap-probe.md)；阶段状态由 coordinator 更新。

### 阶段 B：应用外壳与聊天状态拆分

- [x] 先在 `FeishuChatCore` 写行为测试：看 Email 时收到旧选中聊天的消息，不自动已读、不抑制通知；切回 Messages 时选中会话有未读则补已读；通知路由编解码后切到正确模块；两模块未读汇总与 0 / `99+`。草稿和滚动位置的保留在 app target 中，靠 UI 验收。
- [x] 实现窄导航、模块状态（切换时重建工作区并恢复滚动锚点）、聊天登录局部化、统一 badge 入口及通知路由；`BackendClient` 只把 `detail` 为 `logged_out` 的 409 当聊天登出。自动测试和 Debug 构建通过，滚动恢复已有独立隔离 UI 证据；主要真实系统通知已由F2a独立验证，准确限制见F2a报告。
- [x] UI 验收：在 Email 模块打字和按回车，聊天不发送、草稿不变；切回 Messages 后草稿和滚动位置恢复。独立隔离截图、AX 首可见行与 read/send 计数通过，见 B 验收报告。
- [ ] 保持聊天、隐藏会话、图片展示与现有后端启动流程可用，不借机重写无关聊天逻辑。

B 自动验证、实际调用点和 C/D 接口见 [阶段 B session](../sessions/2026-10-13-email-shell-phase-b.md)。独立结果见 [B 验收报告](../sessions/2026-10-13-email-shell-b-acceptance.md)：核心切换、隐藏、图片、模拟发送/翻页与 SSE 回归通过；系统通知、真实输入法和实际后端启动路径未验，完整聊天回归项继续保留。

### 阶段 C：邮箱后端和缓存

C1 基础已独立实现，交接见 [C1 session](../sessions/2026-10-13-email-foundation-c1.md)。以下子项具有 84 项合成行为测试及后端全量 123 项通过证据；它们不代表下方组合 C 项或 D 的 WebKit/阅读 UI 已完成。

- [x] C1 模型/存储：独立 mail.db 与 user_version 迁移、摘要/原文分离、严格账号/文件夹/UIDVALIDITY/UID 标识与游标、UID 倒序 100/50 缓存分页、账号/世代隔离及删除清理。
- [x] C1 持久化原语：全箱未读快照、同步水位、pending/ack 原子操作、乱序确认与重开恢复；尚未接通知策略/API/SSE。
- [x] C1 MIME：RFC2047/2231、UTF-8→GB18030 与 gb2312/gbk、alternative/related 正文 section、附件元数据及转发子树跳过；真实 IMAPClient FETCH parser 的合成 BodyData 契约验证通过。
- [x] C1 安全基础：响应/头部/正文/深度/部分数限额与单封错误隔离、nh3 HTML 允许列表和读取时重新净化；浏览器执行/网络隔离仍待 D2。

C2 适配器已隔离验证，具体接口与限制见 [C2 session](../sessions/2026-10-13-email-imap-executor-c2.md)；C3a 独立同步服务与 C3b HTTP/SSE/进程生命周期已接通，下方 C 组合项具有后端合成验证证据，不代表 App 或真实邮箱已验收。

- [x] C2 使用真实 IMAPClient 4.1.0 配合 asyncio 脚本化 IMAP/TLS 服务端，验证完整 LIST、INBOX 限制、SELECT/EXAMINE 元数据、稀疏 UID 分页/搜索、摘要 PEEK、选定 section 正文与显式 Seen 的失败校验。
- [x] C2 专用串行 daemon、有界取消/优先队列、世代结果、可中断/续订 IDLE、DONE 未确认断连、库解析前的响应/literal/结构限制和单封错误隔离；正文入队到 wire FETCH 与 FastAPI lifespan 子进程停止的 36 次重复计时均小于 2 秒。DNS 无句柄仅保证限时退役与进程退出，不冒充线程即时取消。

C3a 具体接口与红绿证据见 [C3a session](../sessions/2026-10-13-email-sync-c3a.md)：42 项新增测试，后端全量 221 项通过。以下仅记录独立服务验证证据，不代表 HTTP/SSE、App 或真实邮箱已完成。

- [x] C3a 真实 Store + fake IMAP：UUID 账号/仅内存密码、重建 credential_missing、幂等注入、认证停止重试、地址切换/移除和迟到结果隔离；默认独立 45 秒对账、IDLE/closed、刷新合并与强制换连接。
- [x] C3a 同步/提醒：首次静默与初始化间隙、稀疏 100/50 分页、全箱未读、n:* 过滤、分批存在查询、跨端 flags/删除、UIDVALIDITY 重建、稳定汇总/逐封 pending、重启/乱序 ack、显式 Seen 与离线正文净化。
- [x] C3a 错误与停止：有界缩批/单封解析隔离、可重试摘要占位、退役期间取消仍完成清理、DNS stop_timeout 禁止新建所有者直到 closed；服务 + 真实 C2 + SQLite 的 4 个独立完整进程停止场景均 <2 秒，无默认线程池。

- [x] 测试分两层：服务层用 fake IMAP 适配器；IMAP 适配器本身用脚本化的最小 IMAP 服务端（asyncio TCP，支持 LOGIN/SELECT/EXAMINE/UID SEARCH/UID FETCH/UID STORE/IDLE/DONE，可注入延迟、断线和 IDLE 中的 EXPUNGE）测试选定的真实库。
- [x] 覆盖文件夹完整列举但只读 INBOX、中文名称、按 UID 列表分页、正文按需、附件仅元数据；脱敏 MIME 样本包含 RFC 2047/2231、未声明编码的 GBK 头部、gb2312 声明、转发的 message/rfc822、HTML 与纯文本 alternative。
- [x] 覆盖首次同步不通知、增量去重、无新邮件时 `n:*` 返回的最后一封不触发通知、重连补收与汇总规则、无订阅者时待提醒保留、ack 后才推进水位且重启不重复、UIDVALIDITY 重置、跨端 FLAGS 变化、删除/移动、全收件箱未读与加载页数独立。
- [x] 覆盖读取正文不自动 `\Seen`、显式已读失败不伪报成功、STORE 保留其他 flags、畸形/超大邮件及网络超时不阻塞聊天；IDLE 中到达的取正文请求 2 秒内开始执行；IDLE 进行中停止服务，进程 2 秒内退出。
- [x] 实现 `mail.db` 及 `user_version` 迁移、独立任务生命周期、邮件 API 和 SSE。测试缺失/错误 token 被拒绝、邮箱认证错误不触发聊天登出、`/mail/account*` 的 422 响应和日志不含密码、只注入密码的接口不重置水位、`mail_account_id` 不匹配时拒绝注入、`/status` 带 `features`。

C3b API/SSE 与实际退出证据见 [C3b session](../sessions/2026-10-13-email-api-c3b.md)：真实 loopback HTTP/SSE、合成 IMAP/真实库、请求校验防泄漏、重启 pending/注入、断开/背压，以及阻塞 I/O/试连的完整 SIGTERM 子进程。C1/C2/C3a 的专项随全量回归通过；真实 Seen/新信/睡眠、App 和系统通知继续保留 A/D/E/F 待验。

### 阶段 D：邮箱配置与阅读 UI

- [x] D2 自动实现与验证：原生收件箱/全部文件夹菜单、100/50 不透明分页与已加载前缀刷新、头部/纯文本/HTML/附件信息、当前渲染证据与统一可见性已读、首载前 HTML 规则门与导航/_blank 策略、页外目标缓存摘要 API、E 路由加载入口；后端 301、Core 72、App 46 测试与 Debug 构建通过。见 [D2 session](../sessions/2026-10-13-email-reader-d2.md)；D2 交付时实际 UI/WebKit 尚未验，后续 F1 结果见下面子项；真实跨端 Seen 与剩余 UI/竞态未验，完整 D 项保持未勾选。
- [x] D1 自动实现与验证：Core wire 模型、typed API、安全错误、独立 MailState、原生配置/同步状态、file-based SecItem 可注入包装、ready/SSE 恢复与内存重启、外部/旧后端隔离、整箱 badge/pending、旧账号精确清理及跨重建待删记录、有界按序 SSE 工作；`make test` 与 Debug `make build` 通过。见 [D1 session](../sessions/2026-10-13-email-configuration-d1.md)；不包含配置 UI/真实钥匙串验收，也不代表下方完整 D 项通过。
- [x] F1 独立隔离子项：主要配置/只读试连/移除/旧后端提示、100/50 分页与已加载边界刷新、纯文本/HTML/附件/空态、最小内容800×460、列表锚点与Email键盘回归通过；只用fake SecItem，不代表真实钥匙串。纯文本锚点曾被F1b的新失败覆盖，R2修复现已由下方F1c屏幕证据签收。
- [x] F1 实际 WebKit 子项：恶意原始HTML/净化HTML/纯文本、首封/切回自动资源零请求与禁脚本、HTTP/_blank/IP/localhost 用户外开、规则延迟/失败封闭与拆除视图迟到编译不read通过；故障注入仅在隔离副本。
- [x] F1 可见性已读子项：正文慢/失败/快切目标、切Messages、后台/关窗、离线恢复及结果不确定显式重试有UI与read差值证据。
- [x] R1 自动返修：有界内存文档会话恢复、规则挂载后导航、旧保存/旧navigation隔离；新增14项测试，Core74/App81及Debug构建通过，见 [R1报告](../sessions/2026-10-14-email-html-scroll-r1.md)。实际屏幕落点与新scheme隔离已由F1b独立复验通过，不代表F1/F整体通过。
- [x] F1b独立子项：HTML160切模块/切另一封/快速切换段落及几何恢复，新scheme精确URL子资源/frame/用户链接拒绝与自动资源零增量；规则延迟/失败及身份重置可见已读；浅色、鼠标拖宽、旧cursor完整恢复、fake Keychain缺失/拒绝/锁定/写失败UI通过。见 [F1b报告](../sessions/2026-10-14-email-reader-f1b-acceptance.md)。
- [x] R2自动返修：无窗口SwiftUI宿主复现重建后偏移0，原生只读TextKit按实际布局恢复文字位置；9项新测试覆盖重建/快速切换、窄宽重排、临时顶部/旧回调、身份/正文隔离、空/长正文与检测开关，Core74/App90及Debug构建通过，见 [R2报告](../sessions/2026-10-14-email-plain-scroll-r2.md)。不改HTML契约，屏幕和原生视图主要交互已由F1c独立复验；真实中文组字/精确旧layout仍未验。
- [x] F1c原生纯文本独立复验：正常最新副本159两轮滚动→Messages→Email、159↔158与快速切模块位置/几何一致；鼠标拖宽换行、800×460、深浅色、空/6000行正文、选择复制、只读输入/Return不发聊天及字面资源零增量通过，P2关闭。可见性/身份隔离的实际边界和中文组字/旧layout等未验项见 [F1c报告](../sessions/2026-10-14-email-reader-f1c-acceptance.md)，不关闭整个F1/F/F2。
- [ ] F1剩余：未知能力稳定加载UI、精确旧didFinish乱序与已发STORE期间身份更换、HTTPS/单标签内网外开及跨邮件/token动态攻击；完整边界见F1b报告，下方完整组合项及F2不提前勾选。
- [ ] 实现钥匙串存储（按 `mail_account_id`）、测试连接/保存/后端重启后注入/App 重启恢复、密码失效后停止重试与移除账号；验证凭证不出现在磁盘配置及日志；钥匙串无条目、拒绝访问、锁定分别给出 §3 的提示。
- [ ] 验证隔离：设 `FEISHU_LITE_HOME` 的实例读不到、覆盖不了、删不掉真实条目；外部后端模式不自动注入。实测 Debug 与 Release 构建访问对方创建的条目是否弹授权框，会弹就按构建配置区分钥匙串 service 名。
- [ ] 实现文件夹下拉、收件箱列表、分页、正文阅读、附件信息、手动刷新、后端版本过旧提示和各种空/离线/失败状态。
- [ ] HTML 由后端净化（候选 nh3；缓存解码后的原始正文、读取时净化，调整允许列表不必清缓存），App 用隔离 WebKit 展示：非持久化数据存储、禁用页面 JavaScript、CSP、内容规则拦截所有网络资源（规则表编译并挂上之后才加载第一封邮件）、拦截导航，`target=_blank` 链接经 `createWebViewWith` 外开。HTML 无权访问本地接口 token、聊天凭证或其他邮件数据。
- [ ] 测试恶意 HTML 的脚本、远程图片、CSS URL、iframe、表单和本地 URL 不执行/加载，App 启动后的第一封邮件也一样；允许用户点击的 HTTP(S) 链接外开，其余 scheme 首版拦截。
- [ ] 实现正文成功显示后的可见性校验和已读提交，并在切换模块、App 激活、窗口成为 key 时重新判断；覆盖快速切换条目/模块、请求迟到、账号变更与断线场景。

### 阶段 E：全局未读和通知联调

- [x] 用纯逻辑测试验证两个模块计数汇总、免打扰/隐藏规则、0 与 99+、离线旧计数、账号移除后清零。B Core 与 E 实际 AppState 调用测试通过，F2a已用真实Dock图标与同进程属性验证合计/0/99+/移除账号及离线旧计数，准确范围见F2a报告。
- [x] E 隔离自动实现：消费持久 pending、逐封/汇总投递、同封可见性抑制、自发邮件、部分失败/ack 失败/重启去重、读删/reset/账号与迟到清理、最新通知路由及唤醒合并。未知 intent 不自动重投/不 ack，保留 pending 并提供明确恢复；Core74/App67/后端301项及 Debug 构建通过，见 [E session](../sessions/2026-10-14-email-notifications-e.md)。下方实际通知/跨端联调不凭 recorder 勾选。
- [x] F2a合成服务/真实系统中心：逐封与给定summary模式投递、正文可见同封抑制、其他目标/关窗提醒、成功receipt跨进程仅重试ack、实际点击页外/关窗/汇总/404/当前chat、读删/reset/移除精确清理、Dock证据通过。播种真实待递送请求与未知receipt的边界见 [F2a报告](../sessions/2026-10-14-email-system-notifications-f2a.md)，不代替真实IMAP分类/跨端验证。
- [x] F2b独立子项：R3最小/正常/长计数实际换行/配置正文模块重建及鼠标真实再提醒通过，布局P2关闭；真实测试UUID自身SecItem CRUD/canary、production MailState合成ready/SSE恢复调用、隔离生产Supervisor关窗/崩溃重启/退出、合成唤醒、有限历史/发送/图片/草稿及全量301/Core74/App92与Debug构建通过。跨签名互访出现login钥匙串密码授权框，已触发本计划§D按构建configuration区分service的后续实现条件，由协调者下一阶段处理，无需等待用户密码；当前互访/反向及完整聊天/真实睡眠仍未验，见[F2b报告](../sessions/2026-10-14-email-system-integration-f2b.md)，不勾选完整组合项。
- [ ] F2a剩余：R3布局P2已关闭，Tab/Return仍未验；稳定账号运行中关闭权限未验（disabled首轮fixture旧UUID失败保留，重启拒绝权限通过不覆盖）；410/旧账号点击、遗留聊天payload、真实add/部分失败等见报告。F2b独立子项见上条，完整余项保留，不勾选下方组合项。
- [ ] 验证历史导入静默、实时提醒、重连去重、补收汇总规则（超过 3 封或最早一封早于发现时 10 分钟）、待提醒在 App 重连后补发；通知目标包含领域和账号信息。
- [ ] 验证本地及远端已读后的 badge/通知清理，通知点击跨模块跳转与目标失效回退。

## 7. 验收与完成标准

- 自动检查：`cd backend && uv run pytest`；`cd mac && make test && make build`。新增逻辑先有失败行为测试；不主动跑 formatter/style linter。
- 实机前运行 `agent-inspect-session.sh`，按项目规则处理 context 超过 40% 的情况；先读 `~/.claude/docs/DESKTOP_APP_TESTING.md`。需要 Herdr 验收时使用相应技能。
- 隔离 UI 验证至少覆盖：窄导航选中态及 badge、最小窗口/调整宽度、切换恢复、Email 页回车不发聊天、文件夹菜单、长主题/中文、HTML/纯文本/附件、配置缺失/错误、钥匙串无条目/拒绝、后端版本过旧、离线缓存。隔离实例必须读不到真实邮箱密码；复制真实数据目录做测试时先去掉邮箱配置，验收结束移除测试账号及其钥匙串条目。
- 真实账号验证：列出文件夹、近期与较早收件箱邮件、正文和附件信息、跨端已读、测试新邮件通知、点击通知定位、断线与睡眠唤醒恢复、重启不重复通知。
- 系统通知、登录页或钥匙串授权框会真正显示时，提前告诉用户。真实账号仅打开指定测试聊天和邮件，避免清除工作消息/邮件的未读。
- 回归原有聊天：扫码、历史翻页、发送、实时通知、隐藏会话、图片预览、草稿、Dock badge。确认邮箱认证错误/网络超时不会让聊天停止工作。
- 截图归档 `tmp/<验收日期>-email-reader/`，报告该路径；样本和命令输出不含凭证或真实工作邮件内容。
- 测试结束停止自建后端/探路任务，释放浏览器等资源；按需运行 `mac-dev-cleanup --only browser --min-age 2`。不要清理用户正常使用的 App 会话。
- 所有未通过且影响已交付使用的事项写入 `kb/known-issues.md`；尚未交付的下一版功能留在本计划，不作为已知缺陷。
- 更新受影响的 README、`AGENTS.md` 和 `mac/AGENTS.md`，记录 session；在当前分支提交实现和相关文档，不另建分支/工作树、不自动发布。实际接入未验证时不能将本计划标为全部完成。

## 8. 下一版边界

已明确留到下一版：读取并切换其他文件夹。届时利用本期已保存的文件夹标识与账号/文件夹级邮件键，增加按文件夹同步策略，并重新确定邮箱 badge 是否包含其他文件夹；不能默认把所有文件夹未读简单累加。

附件下载/预览、发送与回复、多账号、邮件串、全文搜索不在本计划内，后续需要独立确定范围。
