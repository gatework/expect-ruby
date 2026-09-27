# 内部状态与数据归属

这些状态供 Matcher、Relay 和会话生命周期协作使用，不是公共接口。

## 模块职责

| 模块 | 职责 |
| --- | --- |
| `expect.rb` | 会话入口、PTY 启动、缓冲、直接读写和关闭流程 |
| `configuration.rb` | 配置校验与可复制的默认快照 |
| `pattern.rb`、`pattern_list.rb`、`result.rb` | 字节定位、声明顺序及原生结果值 |
| `matcher.rb` | 一次等待的匹配、事件派发和期限 |
| `session_resources.rb` | IO、日志与直属子进程的所有权账本和 GC 兜底 |
| `logging.rb` | 日志目标、监听器及同步输出；不持有第二份资源所有权 |
| `terminal.rb` | `stty` 和窗口尺寸的会话终端接口 |
| `interaction.rb`、`relay.rb`、`relay_writer.rb` | 人工接管、转义处理、共同调度和各目标发送游标 |

这些能力文件延续 `interaction.rb` 的类重开方式，公共入口仍是 `expect/pty`。按职责组织方法，不引入新的继承层级，也不复制会话状态。

跨对象调用使用 `__send__` 访问受保护或私有方法。变更以下入口时，应同时检查调用方与失败恢复路径：

| 会话内部入口 | 使用方 | 不变量 |
| --- | --- | --- |
| `reset_result`、`record_match`、`record_eof`、`record_error` | Matcher | 先保存结果再执行回调；错误保留原始输入 |
| `read_available` | Matcher、Relay、写入背压 | 转接缓冲交接时禁止直接传播和裁剪；普通匹配缓冲需要裁剪 |
| `interaction_buffer`、`restore_relay_buffer` | Matcher、Relay | 嵌套匹配及转接退出时把未消费字节交还原所有者 |
| `sequences`、`relay_history`、`relay_callback` | Relay、转义扫描 | 已识别转义只回调一次，已发送前缀不重放 |
| `queue_output`、`relay_outputs`、`propagate` | Relay、转义扫描 | 每个目标独立保存短写进度；同步传播只用于普通匹配 |

| 状态 | 所有者与修改入口 | 交接、超时与关闭 |
| --- | --- | --- |
| `@buffer` | 会话的未消费匹配输入；`read_available` 追加，`record_match` 消费，`clear_buffer` 移交 | Matcher 用公开 `buffer` 的副本扫描；一次扫描的重复来源复用副本，下轮重新获取。超时保留字节。关闭不清空它，便于检查尾部 |
| `@interaction_buffer` | Relay 当前持有的待处理输入；转接背压读取也追加到这里 | 转义回调内的 Matcher 临时移回 `@buffer`；Matcher 的 ensure 将余下字节交回 Relay。Relay 的 ensure 恢复上层交互状态，并把未处理字节还给普通缓冲 |
| `@relay_outputs` | 源会话持有的各目标发送游标；`queue_output` 创建，RelayWriter 推进 | 超时或写失败后保留原目标和已交付位置；重入续发，不重放成功前缀。关闭放弃剩余交付并清空队列，不关闭借用目标 |
| `@relay_history` | 源会话的正则转义历史窗口；`relay_buffer` 更新 | 同一规则跨次转接保留，规则改变或转义消费后清空。窗口遵守 buffer_limit 或内部默认上限，固定 UTF-8 正则不保留开头的孤立续字节。关闭清空 |
| `@relay_callback` | 已识别转义但尚未交付完前缀时，源会话暂存的回调 | 所有前缀目标交付完成后执行一次；超时保留，关闭释放。不能在等待写入后重新扫描这段已识别转义 |

匹配优先级始终是“声明组 → 会话 → 模式”，不是文本位置；多个会话包装同一 IO 时，就绪处理使用对象身份选择首个声明会话。回调前后用于判断缓冲是否变化的快照仍独立保留，不能换成可变内部字符串。零长度或 preserve_buffer 的继续匹配必须遵守 stalled 保护。

文本与 EOF 回调遵守相同的继续期限：`continue(reset_timeout: false)` 返回后先检查原期限，再开始下一轮文本匹配。EOF 继续已到期时仍依次派发已知 EOF，不读取新输入；超时仅通知仍活跃的来源，保留未消费缓冲。所有来源都已 EOF 时直接返回 EOF，不再制造一次超时事件。EOF 或超时回调重置期限后恢复普通匹配顺序。

转义扫描只在一轮内复用 `history + buffer`，只含字面规则时不构造它。回调继续后重新读取规则、历史和缓冲；不能跨回调保存文本快照。字面转义的潜在前缀暂存，完整前缀交付后才执行转义回调。

## 关闭与所有权

SessionResources 保存创建者 PID、所属句柄、直属子进程和所属日志。借用 IO 不关闭，fork 后的非创建者不发送信号或回收父进程的孩子。soft_close 最多发送 TERM 并保留未退出 PID；hard_close 可在有限等待后发送 KILL。

工厂和构造器在校验之前登记资源归属，失败时沿用同一清理流程；启动成功必须显式记录，不能用 PID 非空推断整个工厂调用已经成功。即使 exec 成功后诊断输出失败，也要立即回收未交付给调用方的子进程。

显式关闭遇到 IOError/SystemCallError 时，继续尝试其他句柄、交互包装器、日志和子进程清理，最后传播首个清理错误；已经在传播的其他异常保留。失败资源继续持有，后续关闭可重试。GC 终结器独立尝试句柄、日志、非阻塞回收，常规清理错误不向外传播。终结器不能强引用会话本身。

是否保留原始异常由当前构造、块或关闭作用域显式记录，不能直接读取调用者 rescue 中的 `$!`。`Interrupt` 和 `SystemExit` 同样先清理再传播；`break` / `throw` 不是异常，此时清理失败仍应抛出。

## 回归入口

| 不变量 | 测试 |
| --- | --- |
| 部分关闭失败、错误保留、借用 IO、非 owner、软硬关闭和 GC | cleanup_test、process_test、edge_case_test |
| 字节偏移、二进制和 UTF-8 分片、零长度、可选捕获 | pattern_offset_test、matching_test、ruby_api_test、edge_case_test |
| 一轮快照、同 IO 首来源、回调换规则、嵌套匹配 | scan_reuse_test、multi_session_test、interconnect_test |
| 短写、转义拆包、超时恢复、不重放、回调前缀顺序 | relay_recovery_test、interconnect_test |
| 无限/零/有限超时、继续重置/保留、EINTR、接收重置 | timeout_test（控制输入到达时间）、edge_case_test |
| 总期限和目标写期限、连续中断不延长写超时 | relay_recovery_test |

保留独立的 Matcher、Relay、write、wait 期限合同；仅为去重而统一事件循环会扩大上述状态交接的影响范围。
