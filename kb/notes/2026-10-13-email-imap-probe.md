---
created: 2026-10-13
tags:
  - email
  - imap
  - research
  - python
---

# 邮箱阶段 A：飞书 IMAP 只读能力与库选型

阶段 A 的完成条件已满足：真实只读接入通过，候选库在 Python 3.12 下完成 IDLE 中断及进程退出计时，选定 **IMAPClient 4.1.0**。没有开始应用外壳、后端邮箱领域或 UI 实现；后端依赖尚未改变。真实已读写入、跨端变化及新邮件通知仍需用户指定测试邮件和发件来源，不能把本报告当作整体验收。

依据：[原计划 §2、§4、§6A](../plans/2026-10-13-email-reader-plan.md)及[阶段 A 执行约定](../plans/2026-10-13-email-reader-coordination.md)。执行日期 2026-10-13，当前 master 分支，不建 worktree，不 push、不发布。

## 真实接入证据

脚本通过 `envops read-value --unsafe` 的子进程 stdout 管道把字段交给内存中的 `SecretStr`，不在终端、参数或报告输出值。`--unsafe` 仅用于向程序传值；未直接读取 env 文件。没有开启库的协议日志。报告只保存预先允许的协议标记、布尔值、数量和计时，不保存文件夹名称、UID、邮箱地址、主题、正文或完整服务端响应。

本次共建立 **4 个串行真实连接**，每个连接仅用正确凭证认证一次，没有同时打开探路连接。前两次分别暴露了脱敏报告的 READ-ONLY 序列化问题与 BODYSTRUCTURE 多部分表示问题，补复现测试后修正；后两次完成全部只读操作。以下能力和三次计时来自最后一次完整运行，所有连接均已关闭。

| 检查 | 真实结果 | 证据边界 |
| --- | --- | --- |
| TLS | TLSv1.3，TLS_AES_256_GCM_SHA384，系统 CA 与主机名校验开启并成功 | 没有跳过证书校验 |
| 正常认证 | LOGIN 成功，未在登录前发 ID | 每连接一次正常认证，没有制造错误密码 |
| 认证前 CAPABILITY | AUTH=PLAIN、IDLE、IMAP4REV1、MOVE、UIDPLUS | 以真实返回为准 |
| 认证后 CAPABILITY | APPENDLIMIT=157286400、CHILDREN、ID、IDLE、IMAP4REV1、LITERAL+、MOVE、SASL-IR、UIDPLUS、UNSELECT | 已去掉重复 token |
| 未公布的扩展 | CONDSTORE、QRESYNC、ESEARCH、SORT、SPECIAL-USE、UTF8=ACCEPT | 后续实现按不支持处理，不发送相应扩展命令；未强行尝试未公布扩展 |
| ID | 不发 ID 即可 LOGIN、LIST、EXAMINE；认证后发送 ID 被接受 | 当前账号及这些操作不要求先发 ID，不推广至其他租户 |
| LIST | 9 个文件夹；8 个名称包含中文；2 个名称含层级分隔符 `/`；本次没有 `\Noselect` 条目；INBOX 存在 | IMAPClient 已解码名称，未保存名称；不可选择节点仍要用隔离样本覆盖 |
| EXAMINE INBOX | 返回 READ-ONLY，UIDVALIDITY、UIDNEXT 为整数，FLAGS 与 PERMANENTFLAGS 都包含 `\Seen` | PERMANENTFLAGS 不为空；EXAMINE 中出现 `\Seen` 不能证明 SELECT 后可写或实际持久化 |
| UID SEARCH | ALL 和 UNSEEN 均成功 | 不保存整箱数、UID 或未读 UID 集合；全箱未读统计的协议基础可用 |
| 摘要 FETCH | FLAGS、INTERNALDATE、RFC822.SIZE、BODYSTRUCTURE 正常返回，BODYSTRUCTURE 已解析 | 只抽一封未读邮件；不是全部 MIME 结构覆盖 |
| PEEK | 指定头部字段及由 BODYSTRUCTURE 找出的文本部分前 1024 字节均成功；首次两项 PEEK 前后 FLAGS 完全相同 | 未读样本没有变成已读；未下载附件，未取整封 RFC822 |
| IDLE | 真实 EXAMINE 后能进入 IDLE，DONE 后完成 PEEK；三轮短时等待均无推送 | 不是跨端 flags、新信或长时断开验证 |

真实 IDLE 计时从 `idle_check(timeout=1)` 开始，到 `idle_done()` 完成并再次 PEEK 取文本片段结束：**1.2103、1.2276、1.2189 秒**。这比“开始执行 FETCH”更严格，但属于三次当前网络下的完成时间，不保证所有网络条件都小于 2 秒，也不代表最终应用队列已经实现。最初完整运行还验证了 DONE 后 NOOP，耗时 1.1028 秒，无推送。

## Python 3.12 候选库比较

运行时为 **CPython 3.12.12 / macOS arm64**，候选 **IMAPClient 4.1.0**、**aioimaplib 2.0.3**；脚本模型使用 pydantic 2.14.1。版本固定在各脚本的 uv 元数据中，不改变项目的 `pyproject.toml` 或 `uv.lock`。Python 3.12 的标准库没有现成的 `idle()`，本阶段没有手写 IDLE 协议。[Python 3.12 imaplib 文档](https://docs.python.org/3.12/library/imaplib.html)

| 候选 | 本次发现 | 选择 |
| --- | --- | --- |
| IMAPClient 4.1.0 | 真实 TLS + EXAMINE + IDLE + DONE + PEEK 全链路通过；自带 modified UTF-7、FETCH/BODYSTRUCTURE 解析；1 秒轮询可满足本次请求与关停计时 | 选定，后续用专用 daemon 线程及串行队列 |
| aioimaplib 2.0.3 | 隔离 SELECT 后 IDLE 可迅速打断；但 EXAMINE 成功后 `protocol.state` 仍为 AUTH，随后 `idle()` 抛 `Abort: command IDLE illegal in state AUTH`；另需自行完成结构与文件夹解析 | 不选，不用改库私有状态来绕过 EXAMINE 问题 |

EXAMINE 问题由 `test_aio_examine.py` 在最小服务端复现，使用发布包而非 mock。源码中 `select()` 显式转为 SELECTED，`examine()` 仅调用 `simple_command`，没有相应状态转换。候选计时对 aioimaplib 使用的 SELECT **仅发送到隔离服务端**；真实飞书探路全程只有 EXAMINE。[aioimaplib 官方仓库](https://github.com/iroco-co/aioimaplib)

IMAPClient 实例不能由多个线程并发调用；`idle_check` 有独立轮询时限，`idle_done` 会发送 DONE 并等待 tagged 确认。库的 `logout()` 已关闭连接，再调用 `shutdown()` 可能产生 Bad file descriptor，本次计时脚本已避免重复关闭。后续使用者需明确连接所有者和关闭状态。[IMAPClient 官方 API 与线程安全说明](https://imapclient.readthedocs.io/en/master/api.html)

## 隔离计时与停止证据

`probe_candidates.py` 的 asyncio TCP 最小服务端在 127.0.0.1 随机端口运行，只用虚构凭证和正文 `hello`。提供 CAPABILITY、LOGIN、EXAMINE/SELECT、UID FETCH、IDLE/DONE、LOGOUT，按场景注入 EXPUNGE/EXISTS/FETCH 推送、DONE 不确认或 FETCH 不回应。它是 A 的选型探路工具，不是阶段 C2 的最终适配器测试或实现。

请求场景在 IDLE 已开始后约 50 ms 入队；计时从请求入队开始，到服务端实际收到 UID FETCH 为止。服务端对 DONE 的确认人为延迟 50 ms，并检查确认前没有别的命令进入。停止计时从停止信号开始，到工作线程/任务关闭为止。每种候选每种场景 3 次，共 30 次，全部满足串行、正文一致、连接关闭及小于 2 秒。

| 场景 | IMAPClient 最大秒数 | aioimaplib 最大秒数 |
| --- | ---: | ---: |
| 无推送时 IDLE → FETCH 开始 | 0.997528 | 0.052290 |
| 收到 EXPUNGE/EXISTS/FETCH 推送后，IDLE → FETCH 开始 | 0.999261 | 0.052116 |
| 正常 IDLE 中停止，DONE + LOGOUT | 1.003372 | 0.052641 |
| DONE 永不确认，停止并强制关闭 socket/transport | 0.006336 | 0.000142 |
| FETCH 永不返回，停止并强制关闭 socket/transport | 0.006327 | 0.000135 |

另外启动独立 Python 子进程，把等待 IDLE、等待 DONE 确认、等待 FETCH 响应分别作为停止时刻；父进程发 STOP 后计时至整个子进程退出。每候选每场景 2 次，共 12 次，全部返回 0 且 stderr 为空。测量**不包含解释器启动时间**，也不模拟 App 关闭 UI。

| 子进程退出场景 | IMAPClient 最大秒数 | aioimaplib 最大秒数 |
| --- | ---: | ---: |
| 正常 IDLE | 1.014054 | 0.064029 |
| DONE 永不确认 | 0.019273 | 0.011795 |
| FETCH 永不返回 | 0.020147 | 0.011051 |

IMAPClient 用 daemon 线程，事件循环线程只在强制停止时对已发布的 socket 调用 `shutdown(SHUT_RDWR)`，阻塞操作被打断后由所有者关闭连接。没有调用默认线程池，未出现 `asyncio.run` 等待线程池退出的问题。aioimaplib 对半开连接需 abort transport、取消 pending 命令/推送任务与 IDLE timer 并 await 清理；IMAP `close()` 不等于 TCP teardown。

这些模拟故障没有施加到真实邮箱，隔离 TCP 结果也不替代最终适配器的 TLS、连接建立中关停、响应半行、持续推送和迟到响应测试。

## 交给后续后端开发的约定

- 在实施 IMAP 适配器的阶段用 `uv add` 引入 IMAPClient，锁定并记录版本；A 没有安装到后端项目。
- 一条连接由一个专用 daemon 工作线程持有。所有正常 IMAP 命令通过串行队列执行；正文与已读请求优先于后台同步和分页。不要在事件循环或默认线程池里直接运行同步库，不跨线程操作 Store 或 SSE。
- 用库的 IDLE/DONE；收到任意 EXISTS/EXPUNGE/FETCH 推送只置“需对账”，不把序号当 UID。退出 IDLE 必须等 DONE 的 tagged 确认，再执行 FETCH/STORE。
- 本次 `idle_check(timeout=1)` 已通过选型关卡。最终适配器需给 DONE 确认单独的短期限或整体中断期限，不能沿用 10 秒普通读取超时后宣称请求总能在 2 秒内开始；超时则断开并报告/重连，不能绕过确认并发发送 FETCH。C2 补超时、部分响应和优先级行为测试。
- 正常停止尽量 DONE + LOGOUT；遇到阻塞读立即 shutdown socket，所有者清理；硬性停止期限也需涵盖建连、TLS 握手和 greeting 阶段。工作线程返回携带账号/连接世代，已停止或已换账号的结果丢弃。
- 缺少 CONDSTORE/QRESYNC，按原计划定期 UID SEARCH UNSEEN 对账；无 SORT/ESEARCH，按 UID 列表倒序分页，不用收件时间或 UID 算术分页。UTF8=ACCEPT 未公布，文件夹保留服务端标识并用 modified UTF-7 解码。
- BODYSTRUCTURE 的 multipart 在 IMAPClient 中是 `BodyData([子部分...], subtype, ...)`，不能当连续原始 tuple 遍历。本次脚本只找安全文本片段；正式 MIME 选择、附件大小及转发子树规则仍属 C1/C2。
- IDLE 续订先按协议不超过 29 分钟设计，但本次没有测飞书实际长时断开周期；上线前再记录长期观察并调整。45 秒未读对账不能被 IDLE 阻塞。
- 错误与日志不能直接输出库 exception 文本或原始响应；可能含邮箱地址、命令参数或邮件内容。按邮件领域与失败阶段分类，保留已脱敏原因。

## 可复用脚本与复现

本 checkout 保留 `tmp/2026-10-13-email-imap/`（gitignored，未强制入库），包括：

- `probe_real.py`：envops 加载凭证、只读真实探路，输出 `real-result.json`。
- `probe_candidates.py`：两个真实库对最小服务端的 30 次测量与 12 次独立进程退出，输出 `isolated-result.json`。
- `test_probe.py`：READ-ONLY JSON 脱敏输出、多部分 BodyData 以及不取文本附件的 3 个测试。
- `test_idle.py`：候选中断与独立进程退出的 3 个行为测试（含提前发送 FETCH 的违规客户端检测），分别遍历上述 30/12 个测量。
- `test_aio_examine.py`：aioimaplib EXAMINE 状态问题的 1 个复现测试，输出 `aio-examine-result.json`。
- `inspect_libraries.py` / `library-source.txt`：已安装发布包的关键方法源码与版本；官方文档快照留在同目录。
- `isolated-run.log`：计时脚本输出，无真实邮箱信息。
- `idle-test.log`：最终 3 个行为测试通过记录；`script-manifest.json` 保存脚本 SHA-256，`finalize_evidence.py` 校验 42 个测量与 10 个报告/结果文件不含用户邮箱或密码，`audit_resources.py` 检查无残留探路进程。

在项目根目录执行（真实脚本会读取现有 env 文件，不输出值）：

```sh
uv run --python 3.12 tmp/2026-10-13-email-imap/test_probe.py
uv run --python 3.12 tmp/2026-10-13-email-imap/test_aio_examine.py
uv run --python 3.12 tmp/2026-10-13-email-imap/test_idle.py
uv run --python 3.12 tmp/2026-10-13-email-imap/probe_candidates.py
uv run --python 3.12 tmp/2026-10-13-email-imap/probe_real.py
```

实跑测试均通过：3 + 1 + 3 个测试；计时脚本的 42 个结构化测量全部通过。仅探路工具及文档有变化，无 App/后端业务实现变化，因此没有启动 App、全项目构建、浏览器、模拟器或截图验收。

## 明确未测与待验

| 项目 | 未测原因 / 后续条件 |
| --- | --- |
| SELECT/STORE 权限、`\Seen` 持久化与官方客户端可见 | 没有用户指定的可修改测试邮件；PERMANENTFLAGS 只是协议返回，不能替代写入验证 |
| 官方端已读后 IDLE 是否推送 FLAGS、60 秒内未读对账 | 没有指定测试邮件和跨端操作；本次短时没有推送，不推断“不支持” |
| 真实新信推送、通知及自己发给自己是否进 INBOX | 没有授权邮箱发件来源，不自行发信；聊天 litetest 授权不能移用于邮箱 |
| 长期 IDLE 断开时限 | 只有几轮约 1 秒短时等待，不推断实际长时连接寿命 |
| 最大连接数 | 未增加并发连接或压力测试，不给出上限 |
| 错误密码返回、重试限流和锁号阈值 | 没有制造错误凭证，本次真实认证全部成功；故不声称掌握错误返回内容 |
| 完整 MIME/大正文/无可选文件夹/网络故障/睡眠恢复 | 属后续隔离实现与 F 真实验收；当前只读样本和小型模拟服务不覆盖全部情况 |

阶段 A 的授权边界已落实，以上项目保留给 coordinator 分派后续验证。所有自建 IMAP 连接、本地服务端、daemon 工作线程和子进程已退出；未停止或改动用户 App、正式缓存、钥匙串或通知。
