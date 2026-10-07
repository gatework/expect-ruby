# 内部状态与数据归属

Expect::Session 本身是公开接口；本文所列状态与标为 `@api private` 的方法供 Matcher、Relay 和生命周期协作使用，不是用户契约。

## 模块职责

| 模块                                            | 职责                                                             |
|-------------------------------------------------|------------------------------------------------------------------|
| `expect.rb`                                     | 无状态模块工厂、来源就绪查询与 DSL 构建                          |
| `session.rb`                                    | PTY 生命周期、缓冲、直接读写和结果状态；组合记录、诊断及交互模块 |
| `cleanup.rb`                                    | 异常优先级与始终/失败清理作用域                                  |
| `pattern.rb`、`pattern_list.rb`、`result.rb`    | 字节定位、声明顺序及原生结果值                                   |
| `matcher.rb`                                    | 一次等待的匹配、事件派发和期限                                   |
| `session_resources.rb`                          | 所属 IO 与直属子进程的所有权账本和 GC 兜底                       |
| `logging.rb`                                    | 借用 logger/transcript/outputs 及同步输出；不拥有目标            |
| `interaction.rb`、`relay.rb`、`relay_writer.rb` | 人工接管、转义处理、共同调度和各目标发送游标                     |

`redactor.rb` 提供公共 `Expect::Redactor` 字节过滤接口，供会话日志、各方向诊断及上层库共用，不持有 IO，也不接管协议缓冲。

## 标准库与专用实现的边界

诊断复用 Ruby Logger 的级别、格式和输出协议，终端设置复用 io/console，文件打开与关闭交给调用方的 File.open，结果值复用 Data。
这些能力不再由本库维护配置门面、日志文件所有权或 stty 命令包装。

PTY 控制终端建立、exec 错误管道握手和有限期限的子进程回收继续由 Session 与 SessionResources 负责：会话需要在启动前设置
slave 的 raw 模式，
父进程需要在交付会话前确认 exec 是否成功，关闭时还需保留直属子进程归属及分阶段回收策略。Open3 的普通管道不能替代这些终端语义。
Redactor 则处理分片原始字节中的秘密、跨块前缀和重叠区间；它与 ActiveSupport::ParameterFilter 的参数键值过滤职责不同，不相互替代。

## 会话与协作协议

`Expect` 是模块，工厂返回真实的公开 `Session`，没有门面、连接转换、全局配置或默认值继承。
Session 组合 Logging 与 Interaction；timeout、write_timeout、buffer_limit、logger、transcript、outputs 是显式实例设置。
Matcher 持有本轮 consume/reset_timeout_on_read，spawn/interact/close 各自持有 raw/graceful 参数，不把操作策略保存成配置层。
回调、链式返回与 Result.session 始终是该 Session 本身。终端操作直接使用 Ruby io/console，不启动 stty。

运行状态只属于 Session；SessionResources 不引用 Session、输出目标或用户回调。
终结器通过 `@resources.method(:finalize)` 注册在 Session 上，绑定方法仅持有资源账本，允许会话和捕获它的回调循环一起回收。
`Result` 使用 Data，复制冻结文本与捕获值，但不冻结来源或异常对象。

下列入口是内部协议，不属于用户接口；变更时同时检查调用方与失败恢复路径：

| 会话内部入口                                                 | 使用方                   | 不变量                                                 |
|--------------------------------------------------------------|--------------------------|--------------------------------------------------------|
| `reset_result`、`record_match`、`record_eof`、`record_error` | Matcher                  | 先保存结果再执行回调；错误保留原始输入                 |
| `read_available`                                             | Matcher、Relay、写入背压 | 转接缓冲交接时禁止直接传播和裁剪；普通匹配缓冲需要裁剪 |
| `scan_buffer`                                                | Matcher                  | 仅在当前无回调扫描借用；不得修改或跨读取、回调保存     |
| `take_buffer`                                                | Matcher、Relay           | 移交未消费字节，保留连续转义历史；与公开 clear_buffer 的显式清空边界不同 |
| `interaction_buffer`、`restore_relay_buffer`                 | Matcher、Relay           | 嵌套匹配及转接退出时把未消费字节交还原所有者           |
| `sequences`、`relay_history`、`relay_callback`               | Relay、转义扫描          | 已识别转义只回调一次，已发送前缀不重放                 |
| `queue_output`、`pending_writes`、`propagate`                | Relay、转义扫描          | 每个目标独立保存短写进度；同步传播只用于普通匹配       |

| 状态                  | 所有者与修改入口                                                                      | 交接、超时与关闭                                                                                                                               |
|-----------------------|---------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `@buffer`             | 会话的未消费匹配输入；`read_available` 追加，`record_match` 消费，`take_buffer` 移交 | Matcher 单轮只读借用，避免副本触发下次追加的整窗写时复制；公开 buffer 与回调快照仍复制。超时和关闭保留未消费尾部                               |
| `@received_bytes`     | Session 累计 `read_available` 实际接收的字节数                                    | 在日志与同步输出回调之前登记；缓冲消费、赋值、裁剪及 Matcher/Relay 交接不改变计数，空轮询与 EOF 不计入进展 |
| `@receiving`          | Session 在接收诊断、记录与同步输出期间设置                                           | 同会话递归读取抛出 ReentrancyError；拒绝内层读取不能解除外层保护，交付结束或异常后由 ensure 释放                                               |
| `@interaction_buffer` | Relay 当前持有的待处理输入；转接背压读取也追加到这里                                  | 转义回调内的 Matcher 临时移回 `@buffer`；Matcher 的 ensure 将余下字节交回 Relay。Relay 的 ensure 恢复上层交互状态，并把未处理字节还给普通缓冲  |
| `@pending_writes`     | 源会话持有的各目标发送游标；`queue_output` 创建，RelayWriter 推进                     | 超时或写失败后保留原目标和已交付位置；重入续发，不重放成功前缀。关闭放弃剩余交付并清空队列，不关闭借用目标                                     |
| `@relay_history`      | 源会话的正则转义历史窗口；普通转发及超时排出尾部时更新                                | 同一规则下连续输入跨次转接保留；规则改变、输入消费、改写或裁剪后清空。窗口遵守 buffer_limit 或内部默认上限，固定 UTF-8 正则不保留开头的孤立续字节。关闭清空 |
| `@relay_callback`     | 已识别转义但尚未交付完前缀时，源会话暂存的回调                                        | 保存可 call 对象或 nil；无回调转义使用 STOP lambda。所有前缀目标交付完成后执行一次；超时保留，关闭释放。不能在等待写入后重新扫描这段已识别转义 |

普通转接每轮仍最多排队 16 KiB；排队后将借用缓冲替换为未处理后缀，保持对象身份，不逐块原地删除前缀。
已排队字节、公开 Result 快照与后续缓冲修改保持隔离，不能以改变交付顺序或丢弃余量换取性能。

匹配优先级始终是“声明组 → 会话 → 模式”，不是文本位置；来源去重、相邻组比较及 EOF 归属均按会话对象身份，
不能由自定义 `==` / `eql?` / `hash` 合并独立来源。就绪查询与转接的 IO 归属及去重同样使用对象身份。多个会话包装同一 IO
时，匹配器每轮只读取该 IO 一次，归属选择首个声明会话；就绪查询仍返回各自的会话。stalled_matches 与嵌套匹配的 relay_buffers
也按对象身份保存。回调前后用于判断缓冲是否变化的快照仍独立保留，不能换成可变内部字符串。零长度或
consume:false 的继续匹配必须遵守 stalled 保护。停滞判断同时记录接收计数；嵌套 Matcher 或其他回调实际读入新字节后，
即使缓冲内容相同也恢复该来源的全部模式。仅缓冲代次变化或同值赋回不能冒充接收进展。

文本与 EOF 回调遵守相同的继续期限：`continue(reset_timeout: false)` 返回后先检查原期限，再开始下一轮文本匹配。EOF
继续已到期时仍依次派发已知 EOF，不读取新输入；超时仅通知仍活跃的来源，保留未消费缓冲。所有来源都已 EOF 时直接返回
EOF，不再制造一次超时事件。EOF 或超时回调重置期限后恢复普通匹配顺序。
已处理 EOF 的集合按对象身份保存；来源总数来自去重后的声明列表。后续 `IO.select` 失败只为仍活跃来源记录原始异常，
并返回首个活跃来源的结果，不覆盖已经派发的 EOF 及其尾部快照。

转义扫描只在一轮内复用 `history + buffer`，只含字面规则时不构造它。回调继续后重新读取规则、历史和缓冲；不能跨回调保存文本快照。字面转义的潜在前缀暂存，完整前缀交付后才执行转义回调。
总期限结束时排出的字面前缀也加入已启用的正则历史；后续调用可以匹配跨边界的正则转义，已经交付的前缀不可撤回。
正数转接预算在每次扫描、直接及延迟转义继续回调、EOF 继续回调之后重新检查；到期不再消费后续转义，
显式停止仍返回来源会话。零超时保留既有缓冲处理和首次轮询，不把用户回调当作可抢占任务。
正则历史与下次扫描的缓冲必须连续。匹配实际消费 before/match、显式 buffer= / clear_buffer 或窗口裁剪都会清空历史；
否则 ST → expect 消费 NOISE → OP 会错误拼成 STOP。内部 take_buffer 只移交所有权，不建立新的输入边界；
未消费字节的匹配和空等待同样保留历史，包含真正消费零字节的零宽匹配。EOF 消费尾部时沿用显式清空。

Relay 在移动缓冲、恢复写入期限之前检查全部来源的 `relay_owner`，有重叠时抛出 `ReentrancyError`。
重复来源先去重，标记检查和登记只使用短临界区；不跨 IO 或用户回调持锁。退出及准备失败时只归还已转移的缓冲，
只释放当前调用的 token，不能清除外层标记。不同来源的嵌套转接、转义回调中的 Matcher 和转接返回后的顺序恢复保持可用。
自定义目标先产生副作用再抛错而不返回计数时，库不能猜测进度；该协议边界不承诺恰好一次，也不承诺通用线程安全。

## 关闭与所有权

SessionResources 只保存所属句柄、直属子进程及其所有者 PID。初始所有者为资源创建进程；登记新 PID 时改为实际启动它的进程，
因此父进程创建的 PTY 可以在 fork 后启动并回收新的直属子进程。仅继承已有 PID 的副本不改变所有者，不发送信号或回收父进程的孩子。借用
IO 不关闭。soft_close
最多发送 TERM 并保留未退出 PID；hard_close 可在有限等待后发送 KILL。

工厂和构造器进入方法体后先保留资源归属，已知设置校验失败沿用同一清理流程；未知关键字在 Ruby 调用入口拒绝，不接管
IO。启动成功必须显式记录，不能用 PID 非空推断整个工厂调用已经成功。即使
exec 成功后诊断输出失败，也要立即回收未交付给调用方的子进程。
启动错误管道的两个端点均须尝试关闭；fork/exec 的原始失败先于常规清理错误传播，不能被管道或 PTY 关闭失败覆盖。
fork 与父进程登记 PID 构成同一个接管区间；该区间延迟线程异步中断，避免清理时找不到已经创建的子进程。
子进程恢复即时中断；父进程的错误管道等待、日志及后续操作不在延迟区间内。

Session.allocate 或资源账本构造本身也可能被中断。会话未建立时，open 按局部 own 关闭输入端点；账本尚未发布时，
`cleanup_session` 仅按局部 `own` 关闭真实 IO，按对象身份去重，
一端失败仍尝试其他端；借用 IO 保持打开。账本存在后仍调用统一的 `close`，不维护第二份生命周期状态。
`Cleanup.always` 记录本次作用域是否已有主异常；存在时只抑制清理中的 StandardError，保留同一主异常对象。
这包括 transcript writer 或 Logger formatter 抛出的 RuntimeError；没有主异常时仍传播清理错误。
清理中新发生的 Interrupt/SystemExit 等非 StandardError 不吞掉。
内部动作使用 `close_resources`、`close_child`、`mark_eof` 等直接名称，不保留旧私有方法别名。

显式关闭遇到 IOError/SystemCallError 时，继续尝试其他句柄、交互包装器、过滤尾部和子进程清理，最后传播首个清理错误；外围
Cleanup 仍按上述主异常规则处理。失败资源继续持有，后续关闭可重试。GC
终结器独立尝试句柄关闭和非阻塞回收，常规清理错误不向外传播。终结器不能强引用会话本身。

`SessionResources#reap` 只做一次非阻塞系统调用，EINTR 交给所属流程决定：主会话 `process_status` 返回当前未知/缓存状态，
`wait_for_child` 沿用阶段开始时的绝对期限，并在重试间休眠。自然等待、TERM 等待分别使用调用方预算，硬关闭的 KILL 阶段保留 1
秒预算；
零预算也先尝试一次，信号 EINTR 不重新计时。soft_close 不发 KILL，ECHILD 清空 PID，ESRCH 后仍尝试回收，预算耗尽也返回已取得的状态。
GC 只做一次非阻塞回收、最多两次 KILL 尝试及一次 detach；回收/信号 EINTR 不跳过后续阶段，不执行用户日志回调。
detach 成功才移交 PID，失败则保留未知 PID/status。每个操作仍受子进程所有者归属约束；持续系统调用失败只保证有限尝试，不保证返回前退出。

是否保留原始异常由当前构造、块或关闭作用域显式记录，不能直接读取调用者 rescue 中的 `$!`。`Interrupt` 和 `SystemExit`
同样先清理再传播；`break` / `throw` 不是异常，此时清理失败仍应抛出。

## 缓冲裁剪与字面扫描

`buffer_discarded_bytes` 随会话累计，只在匹配窗口执行 `trim_buffer` 时增加。读取、`buffer=`
、降低上限和下一次匹配应用上限都可能触发裁剪；匹配消费、清空、EOF 和 Relay 交接不计入，关闭后仍保留计数。它是可观察的丢弃量，不是缓冲满事件，也不提供全文归档。

`@buffer_generation` 仅在替换、消费、清空、裁剪和 Relay 恢复时递增，同代次只追加。Matcher
按会话与模式对象身份记录字面未命中的代次、字节数及模式值；新增输入只回看模式长度减一的重叠区。无新字节可跳过重复扫描，代次或模式值改变则从头扫描。缓存只活在一次
Matcher 中，不保留文本副本。正则仍扫描完整窗口，不推断其长度、锚点或前瞻范围。

## 相对期限与总期限

公共 `deadline:` 使用 `Expect.monotonic` 的有限绝对秒数，`nil` 表示无总期限；它与 `timeout` 取较早者。
`reset_timeout_on_read` 及所有继续回调只能重置相对期限，总期限固定。总期限过后不读取或消费新的文本匹配；正则计算结束后也要重查期限。已知
EOF 保留派发顺序，全部来源已 EOF 时直接返回 EOF。

未设置总期限时，`timeout: 0` 保持现有缓冲匹配和首次非阻塞轮询语义。期限检查是协作式的，不强行打断单次正则、transcript、outputs
或用户回调；正则执行限时由调用方的 `Regexp` 实例控制。

直接写入及 Relay 目标的 `write_timeout` 用于背压等待和中断重试，不是持续成功短写的总耗时限制。
匹配 `deadline`、写入期限和 Relay 总 `timeout` 分别管理，不自动把匹配期限传给回调中的写入。
直接写入必须先验证计数为正整数且不超过本次 chunk，再推进 offset；`:wait_writable` 仍进入背压路径，空输入返回 0。
`WriteTimeout#bytes_written` 只计本次调用已确认的字节；发送前对象转换或诊断引发嵌套写入超时时，当前进度为 0；
读取输出引发嵌套写入超时时，对外保留当前写入进度。两处均将原异常保留在 cause。
send_slow 累计此前成功字符的字节数；仅当前字符 write 抛错时加上它报告的部分进度。
对象转换、字符间等待和回复交付发生的内层 WriteTimeout 只能作为 cause，不能把内层进度算进本次命令。
首字符 write 的原错误无需调整时原样传播；其余情况包装为累计进度。按字节续发可从多字节字符内部继续，不按字符个数切分。

## 诊断与脱敏归属

`logging.rb` 分开处理 transcript、logger 和 outputs，全部借用且不进入资源账本。默认 transcript/logger 为 nil，outputs 为空。
logger 使用标准 `add` / `debug?` 协议，级别与格式由 Logger 控制；INFO 为生命周期和匹配，DEBUG 为原始收发内容。
传给 add 的冻结事件 Hash 包含 event/pid/fd/message，message 字符串也冻结，不含会话对象。
ActiveSupport 兼容对象可直接注入，不引入框架依赖，也不再包装 IO、callable 或 stderr 默认分支。
诊断失败与其他同步 IO 错误一样保留已读入的原始数据。

`redactor.rb` 是无 IO 的公共字节过滤器。会话复制并追加注册秘密，transcript 以及发送、接收诊断各自持有过滤器。
暂存最长秘密长度减一的尾部，重叠秘密合并为隐藏区间，过滤发生在 inspect 转义之前；不生成会因消费或裁剪而失去上下文的 buffer
诊断。

公共构造器及 `patterns=` 会校验并复制秘密；空模式列表直接交付字节，更新规则不清除已经建立的掩码。
同一模式的命中按字节偏移递增枚举，相交或相邻区间合并后才写入掩码；不能通过跳过整个秘密长度省略重叠命中。
合并仍与现有掩码取并集，保留其他模式和旧规则已标记的隐藏字节，不改变跨块连续区间只输出一个替换标记的规则。
过滤器记录保留窗口中已扫描的字节数，各模式只从可能跨越新增字节的起点继续查找；释放前缀时同步扣减该计数。
`patterns=` 清零扫描进度，让新规则覆盖全部保留字节，同时保留旧掩码；零长度释放不切片，避免空输出时制造共享副本。
默认替换标记为 `[FILTERED]`，上层库可显式指定自己的标记。类方法 `redact` 使用独立流并以 `finish(partial: false)` 结束完整文本；
`append`/`finish` 的默认流策略仍隐藏末尾疑似秘密前缀。作用域所有权、终端渲染和异常字段选择由调用方负责。

EOF 结束接收流，日志或诊断目标替换先冲刷旧流，显式关闭结束所有方向；尾部疑似秘密前缀保守隐藏。GC
只清理所属资源，不执行用户回调或过滤尾部输出。调用方需显式关闭以交付尾部；借用 transcript、logger 和 outputs
不关闭，文件权限、打开与关闭全部由调用方负责。

transcript/logger 替换前先冲刷旧过滤流，失败保留旧目标。冲刷循环排空回调新追加的尾部；诊断对方向快照遍历，交接前的发送和接收仍归旧目标。
匹配诊断中的嵌套等待可消费缓冲，但不能替换外层已记录的 Result 或正式模式回调所见结果。

过滤不修改匹配缓冲、Result 或 outputs，不推断编码、转义等变换后的秘密，也不能追溯删除已交付记录。
同步目标须及时返回；自定义回调抛出的非 IO 异常原样传播。

接收块进入缓冲后，诊断、transcript、同步 outputs 交付受同会话读取保护，防止后块越过当前块进入其他目标。
这些回调仍可匹配已有字节或读取独立会话；同源新读取明确抛出 ReentrancyError，ensure 释放保护。转义回调在交付区间之外，
继续允许嵌套 Matcher。此保护不提供线程安全，也不承诺重放已失败的日志或同步输出。

诊断的 DEBUG 级别关闭不切断原始匹配上下文。Redactor 的内部 suppress 同步推进秘密区间并标记不可输出字节；
后续 append、规则更新、finish 都不得释放关闭期间的原文。未使用 suppress 的普通过滤路径不分配这份额外标记。
RelayWriter 在底层确认短写后先推进游标，再提交目标 Session 的发送诊断，复用直接 write 的发送过滤器；失败不回退已接受字节。
诊断中的嵌套 WriteTimeout 对外报告本游标进度，通过 cause 保留内层异常；普通直接 write 的发送诊断仍在写入前记录尝试内容。

## 生命周期与错误边界

会话 IO、输入 EOF 与直属子进程状态是正交维度。软关闭后 `closed?` 与 `alive?` 同时为真是合法结果；借用 IO、外部关闭和外部
`waitpid` 也不能被单个线性枚举准确替代。外部已回收的 PID 必须清除，无法取得的退出状态保持未知。

参数问题使用 `ArgumentError`；匹配等待的 EOF 和超时保留为 Result 事件，底层 IO 异常保留原对象；`SpawnError` 表示启动失败，
`WriteTimeout` 继承 `IOError` 并携带写入进度。不得仅为统一命名而包装所有错误、丢失原异常或混淆等待事件与失败。

## 新增回归入口

| 不变量                                                                                         | 测试                                                           |
|------------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| 原生 io/console 模式、窗口尺寸及人工接管恢复                                                   | terminal_test、interact_test                                   |
| 明确会话设置、每轮策略、公开类型和初始化失败所有权                                             | session_options_test、interface_contract_test                  |
| 值相等的独立来源、stalled 保护和嵌套转接缓冲归还                                               | session_identity_test、relay_identity_test、multi_session_test |
| 裁剪计数、正常消费、转接交接与日志错误                                                         | buffer_accounting_test                                         |
| 外部回收、借用 IO、关闭失败重试、原生错误分类                                                  | lifecycle_contract_test                                        |
| 绝对期限、接收和回调重置、过期文本、EOF、EINTR、零轮询                                         | deadline_test                                                  |
| 标准 Logger、借用 transcript、分片秘密、二进制、流尾部与重入                                   | diagnostics_test                                               |
| 公共过滤器独立加载、完整文本与分块、空规则、规则更新、输入复制、安全摘要及固定种子字节区间差分 | redactor_test                                                  |
| 字面跨读取命中、声明优先级、缓存失效、操作序列与全量扫描对照                                   | literal_scan_test                                              |
| 同 IO 有界窗口、诊断级别切换、转接短写诊断恢复、回调期限及接收重入保护                          | stream_contract_test                                           |
| 转接历史连续性、显式输入边界、非消费匹配与内部交接；慢速发送的外层累计进度                      | relay_history_test、write_contract_test                         |

## 既有回归入口

| 不变量                                                   | 测试                                                              |
|----------------------------------------------------------|-------------------------------------------------------------------|
| 部分关闭失败、错误保留、借用 IO、非 owner、软硬关闭和 GC | cleanup_test、process_test、edge_case_test                        |
| 字节偏移、二进制和 UTF-8 分片、零长度、可选捕获          | pattern_offset_test、matching_test、ruby_api_test、edge_case_test |
| 单轮缓冲借用、同 IO 首来源、回调换规则、嵌套匹配         | scan_reuse_test、multi_session_test、interconnect_test            |
| 短写、转义拆包、超时恢复、不重放、回调前缀顺序           | relay_recovery_test、interconnect_test                            |
| 无限/零/有限超时、继续重置/保留、EINTR、接收重置         | timeout_test（控制输入到达时间）、edge_case_test                  |
| 总期限和目标写期限、连续中断不延长写超时                 | relay_recovery_test                                               |

保留独立的 Matcher、Relay、write、wait 期限合同；仅为去重而统一事件循环会扩大上述状态交接的影响范围。
