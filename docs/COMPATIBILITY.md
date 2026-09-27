# Ruby 接口与 Expect 行为对照

## Tcl Expect 语义边界

参考 Tcl Expect 的[官方手册](https://core.tcl-lang.org/expect/doc/trunk/expect.man)、
[`expect.c`](https://core.tcl-lang.org/expect/raw/expect.c?ci=trunk) 的 `eval_cases` / `expMatchProcess` / 计时循环，
以及 [`exp_inter.c`](https://core.tcl-lang.org/expect/raw/exp_inter.c?ci=trunk) 的 `intMatch` 与终端恢复流程。
本库借鉴交互模型，保留以下明确差异，不承诺 Tcl 脚本或完整功能兼容。

| Tcl Expect 能力                       | 本库的 Ruby 表达与边界                                                                                                              |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| `spawn`、`send`、`expect`、`interact` | PTY 会话、`write` / `puts`、原生模式块和人工接管；`send` 保留 Ruby 反射语义                                                         |
| `exp_continue` / `-continue_timer`    | `continue` / `continue(reset_timeout: false)`；使用单调时钟和秒数关键字参数                                                         |
| 匹配后消费输入、`-notransfer`         | `before` / `match` / `after` 与会话级 `preserve_buffer`；无进展回调不会原地重复执行                                                 |
| glob、exact、regexp 模式              | 字符串只作字面匹配，正则采用 Ruby `Regexp`；锚点和多行行为遵守 Ruby                                                                 |
| `match_max`、`full_buffer`            | `buffer_limit` 只保留尾部字节，默认无限；`buffer_discarded_bytes` 统计累计裁剪量，无缓冲满事件                                         |
| 前置/后置模式、后台匹配               | 没有全局隐式规则或后台读取器；调用方显式组合模式块，每个会话由一个读取者驱动                                                        |
| `interact` 的部分正则匹配             | Tcl 的 `CANMATCH` 可以暂存潜在匹配；Ruby 原生正则不提供该接口，本库使用有限历史窗口，已转发前缀不能撤回。需要完整过滤时使用字面转义 |
| `close` 与 `wait`                     | IO 结束与进程退出仍分开判断；本库的块生命周期和 `close` 会额外回收直属子进程                                                        |

长输出任务应通过日志或监听器流式保存，并按提示长度设置 `buffer_limit`。只读 `buffer_discarded_bytes` 提供会话累计裁剪字节数，正常匹配消费和清空不计入；它不是无损缓冲满事件。后台匹配与共享前置/后置模式也需要独立的取消、优先级和资源归属约定，尚未实现。

`expect` / `expect_result` 的 `deadline:` 是额外的绝对单调时钟总期限，限制相对 `timeout` 的所有重置，不改变已知 EOF 派发和未指定总期限时的零超时轮询。会话 `diagnostic_output` 与接收日志独立；显式 `redact` 仅过滤日志和诊断，协议转发与匹配仍使用原始字节。

## Expect.pm 接口迁移

交互能力参考 [jacoby/expect.pm](https://github.com/jacoby/expect.pm)，源码基准为版本 1.38、提交
`2ea0e4ce20a896c95cb4c94e781f1b1f3145150d`。此项目独立实现，使用 MIT 许可，没有复制 Perl 实现代码；原项目作者及维护者为
Austin Schutz、Roland Giersig、Dave Jacoby，采用与 Perl 相同的许可。

从 0.2.0 起采用 Ruby 原生接口。下表列出迁移关系， **旧方法、别名和参数语法已移除**；历史 0.1.1 安装包的接口见对应版本记录。

| 原接口或状态                               | 当前 Ruby 接口                                                      |
|--------------------------------------------|---------------------------------------------------------------------|
| 包级默认值、`Expect.defaults`              | `Expect.configure { \|config\| ... }`、冻结的 `Expect.configuration` |
| `timeout(10)` 等读写合一方法               | `timeout`、`timeout = 10`；布尔查询使用 `name?`                     |
| `exp_init`、`init`                         | `Expect.open(io, writer:, own:)`，支持块生命周期                    |
| `expect(seconds, ...)`                     | `expect(..., timeout: seconds)`；完整结果使用 `expect_result`       |
| `-ex`、`-re`、数组字符串正则               | 字符串字面匹配，正则使用原生 `Regexp`                               |
| `-i` 分组                                  | `from: session` / `from: [sessions]`，或块内 `on(..., from:)`       |
| `[pattern, callback, *args]`               | `on(pattern) { \|session\| ... }`，附加参数使用闭包 |
| `exp_continue`、`exp_continue_timeout`     | `continue`、`continue(reset_timeout: false)`                        |
| 数字前缀错误字符串                         | `Result#error` 为 `:timeout`、`:eof` 或原始 IO 异常对象             |
| `matchlist`、`exp_matchlist`               | `captures`                                                          |
| `exp_pid`、`exp_match` 等别名              | `pid`、`match` 等属性                                               |
| `get_accum`、`set_accum`、`clear_accum`    | `buffer`、`buffer=`、`clear_buffer`                                 |
| `max_accum`、`match_max`                   | `buffer_limit`，正整数；`nil` 表示无限                              |
| `notransfer`                               | `preserve_buffer`                                                   |
| `restart_timeout_upon_receive`             | `reset_timeout_on_read`                                             |
| `log_user`、`log_group`                    | `log_stdout`、`log_listeners`                                       |
| `log_file`、`logfile`、`exp_logfile`       | `log_output` / `log_output=`；路径和日志块使用 `log_to(..., mode:)` |
| `print_log_file`                           | `write_log`                                                         |
| `set_group`                                | `listeners` / `listeners=`                                          |
| `set_seq(sequence, callback, args)`        | `on_sequence(sequence) { ... }`                                     |
| `send`、`print`                            | `write` 原样写入、`puts` 按行输出；`send` 保留 Ruby 反射语义        |
| `send_slow(delay, *strings)`、`write_slow` | `send_slow(*objects, delay:)`                                       |
| `manual_stty = true`                       | `raw_terminal = false`；`stty` 保留，`exp_stty` 移除                |
| `interact(input, escape)`                  | `interact(input:, escape:, output:, timeout:)`                      |
| `test_handles` 的索引数组                  | `readable_sessions(*sessions, timeout:)` 返回会话对象数组           |
| `wait(seconds)`                            | `wait(timeout: seconds)`，返回 `Process::Status`                    |
| `exitstatus`、`exp_exitstatus` 原始整数    | `process_status.to_i`；普通退出码用 `exit_code`                     |
| `do_soft_close`                            | `graceful_close`，可通过 `close(graceful:)` 单次覆盖                |
| `debug`、`exp_internal`                    | `debug_level`，整数 `0..3`                                          |
| `ttyname`、`pty_handle`                    | `tty_name`、标准 `inspect`                                          |
| `version`                                  | 常量 `Expect::VERSION`                                              |
| `multiline_matching`                       | 原生正则的 `^` / `$`、`\A` / `\z` 和 `/m`                           |
| `ignore_eintr`                             | 匹配等待自动重试 EINTR，并保留原期限                                |

## 保留的交互能力

仍支持真实控制终端、精确/正则匹配、模式优先级、捕获组、二进制与分片
UTF-8、EOF/超时回调、绝对期限与接收重置、多会话、缓冲上限、慢速写入和背压、路径/IO/回调日志、监听组、人工接管、跨读取转义及终端恢复。

`expect` 返回模式序号或 `nil`；`expect_result` / `last_result` 返回原生七字段 `Struct`。`to_a`、`to_h`、模式解构使用 Ruby
自带行为，多重赋值需要显式 `result.to_a`。日志按实际读取时记录，转接与匹配切换不重复写日志；显式启用 `redact` 时过滤已注册秘密。

## 软关闭与硬关闭

参考原版的策略边界：`soft_close` 先收集剩余输出，关闭所属句柄，等待退出并最多发送 TERM； **不发送 KILL**。未退出返回 `nil`，保留
PID。`hard_close` 不等待输出，必要时 TERM、KILL 并回收子进程。关闭会话 IO 不代表子进程已经退出。

Ruby 使用关键字指定各阶段期限，关闭方法返回 `Process::Status` 或 `nil`。`close(graceful: true)` 和 `graceful_close = true`
先尝试软关闭，再在 `ensure` 中硬关闭；这对应原版销毁时可选软关闭、随后硬关闭的清理策略。`close` 返回 `nil`；GC
兜底直接强制清理，不阻塞等待。

## 有意采用的 Ruby 语义

- 默认关闭 stdout 输出，显式启用 `log_stdout`。配置按会话隔离，构造参数覆盖全局默认；配置异常不发布部分状态。
- 仅 `nil` 和 `false` 为假，`0` 为真。转接回调也采用此规则。
- 字符串始终是字面文本；只有 `:eof` / `:timeout` 是事件，`"EOF"` 是普通转义文本。
- 超时回调接收所有仍在监听的会话；重复注册超时回调抛出 `ArgumentError`。
- `write` 返回字节数，`puts` 返回 `nil`，`<<` 返回会话。
- 启动失败抛出 `Expect::SpawnError` 并回收；EOF 不主动终止仍存活的进程。借用 IO 不关闭，接管 IO 在初始化失败或会话关闭时释放。
- Perl 特有的正则、IO::Pty 继承 API、全局信号 handler 和 Solaris 字节删除补丁不移植。Ruby 使用 `to_io`、`slave`、`io/console`
  和原生正则。

`test/compare_upstream.rb` 仅对共同的交互行为作可选差分验证，通过 Ruby 新接口表达同样场景，并显式转换错误标记和可读会话索引；它不要求或证明旧
API 兼容，也不等于运行完整上游测试套件。
