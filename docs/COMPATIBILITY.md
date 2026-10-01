# Ruby 接口与 Expect 行为对照

## Tcl Expect 语义边界

参考 Tcl Expect 的[官方手册](https://core.tcl-lang.org/expect/doc/trunk/expect.man)、
[`expect.c`](https://core.tcl-lang.org/expect/raw/expect.c?ci=trunk) 的 `eval_cases` / `expMatchProcess` / 计时循环，
以及 [`exp_inter.c`](https://core.tcl-lang.org/expect/raw/exp_inter.c?ci=trunk) 的 `intMatch` 与终端恢复流程。
本库借鉴交互模型，保留以下明确差异，不承诺 Tcl 脚本或完整功能兼容。

| Tcl Expect 能力                       | 本库的 Ruby 表达与边界                                                                                                              |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| `spawn`、`send`、`expect`、`interact` | PTY 会话、`write` / `puts`、原生模式块和人工接管；`send` 保留 Ruby 反射语义                                                         |
| `exp_continue` / `-continue_timer`    | `Expect.continue` / `Expect.continue(reset_timeout: false)`；使用单调时钟和秒数关键字参数                                                         |
| 匹配后消费输入、`-notransfer`         | `before` / `match` / `after` 与每轮等待的 `consume: false`；无进展回调不会原地重复执行                                                 |
| glob、exact、regexp 模式              | 字符串只作字面匹配，正则采用 Ruby `Regexp`；锚点和多行行为遵守 Ruby                                                                 |
| `match_max`、`full_buffer`            | `buffer_limit` 只保留尾部字节，默认无限；`buffer_discarded_bytes` 统计累计裁剪量，无缓冲满事件                                         |
| 前置/后置模式、后台匹配               | 没有全局隐式规则或后台读取器；调用方显式组合模式块，每个会话由一个读取者驱动                                                        |
| `interact` 的部分正则匹配             | Tcl 的 `CANMATCH` 可以暂存潜在匹配；Ruby 原生正则不提供该接口，本库使用有限历史窗口，已转发前缀不能撤回。需要完整过滤时使用字面转义 |
| `close` 与 `wait`                     | IO 结束与进程退出仍分开判断；本库的块生命周期和 `close` 会额外回收直属子进程                                                        |

长输出任务应通过 transcript 或 outputs 流式保存，并按提示长度设置 `buffer_limit`。只读 `buffer_discarded_bytes` 提供会话累计裁剪字节数，正常匹配消费和清空不计入；它不是无损缓冲满事件。后台匹配与共享前置/后置模式也需要独立的取消、优先级和资源归属约定，尚未实现。

`expect` 的 `deadline:` 是额外的绝对单调时钟总期限，限制相对 `timeout` 的所有重置，不改变已知 EOF 派发和未指定总期限时的零超时轮询。会话 `logger` 与接收记录 `transcript` 独立；显式 `redact` 仅过滤日志和诊断，协议转发与匹配仍使用原始字节。

## 实现来源

交互能力参考 [jacoby/expect.pm](https://github.com/jacoby/expect.pm)，源码基准为版本 1.38、提交
`2ea0e4ce20a896c95cb4c94e781f1b1f3145150d`。此项目独立实现，使用 MIT 许可，没有复制 Perl 实现代码；原项目作者及维护者为
Austin Schutz、Roland Giersig、Dave Jacoby，采用与 Perl 相同的许可。

## 保留的交互能力

仍支持真实控制终端、精确/正则匹配、模式优先级、捕获组、二进制与分片
UTF-8、EOF/超时回调、绝对期限与接收重置、多会话、缓冲上限、慢速写入和背压、借用 writer 的接收记录、标准 Logger 诊断、outputs 转发图、人工接管、跨读取转义及终端恢复。

`expect` / `last_result` 返回不可变七字段 `Data`，匹配序号通过 `number` 读取。使用 `to_h` 或模式解构；
字段及文本快照不可修改，不提供 `to_a`。日志按实际读取时记录，转接与匹配切换不重复写日志；显式启用 `redact` 时过滤已注册秘密。

## 软关闭与硬关闭

参考原版的策略边界：`soft_close` 先收集剩余输出，关闭所属句柄，等待退出并最多发送 TERM； **不发送 KILL**。未退出返回 `nil`，保留
PID。`hard_close` 不等待输出，必要时 TERM、KILL 并回收子进程。关闭会话 IO 不代表子进程已经退出。

Ruby 使用关键字指定各阶段期限，关闭方法返回 `Process::Status` 或 `nil`。`close(graceful: true)` 或工厂块的 `graceful: true`
先尝试软关闭，再在 `ensure` 中硬关闭；这对应原版销毁时可选软关闭、随后硬关闭的清理策略。`close` 返回 `nil`；GC
兜底直接强制清理，不阻塞等待。

## 有意采用的 Ruby 语义

- 默认 `outputs: []`，需要显示时显式加入 `$stdout`。会话设置由关键字传入并按实例隔离，没有全局默认配置。
- `Expect` 为模块，公开 `Expect::Session`；回调和结果引用真实 Session，不经过门面转换。
- `raw`、`consume`、`reset_timeout_on_read`、`graceful` 都是所属操作的显式关键字；不保存同名布尔配置。
- logger/transcript/outputs 均借用。文件打开、权限和关闭由调用方负责；兼容标准 Logger 协议的 ActiveSupport logger 可直接注入。
- 仅 `nil` 和 `false` 为假，`0` 为真。转接回调也采用此规则。
- 字符串始终是字面文本；只有 `:eof` / `:timeout` 是事件，`"EOF"` 是普通转义文本。
- 超时回调接收所有仍在监听的会话；重复注册超时回调抛出 `ArgumentError`。
- `write` 返回字节数，`puts` 返回 `nil`，`<<` 返回会话。
- 启动失败抛出 `Expect::SpawnError` 并回收；EOF 不主动终止仍存活的进程。借用 IO 不关闭，接管 IO 在方法体进入后的初始化失败或会话关闭时释放；未知关键字在调用入口拒绝，不接管 IO。
- Perl 特有的正则、IO::Pty 继承 API、全局信号 handler 和 Solaris 字节删除补丁不移植。Ruby 使用 `to_io`、`slave`、`io/console`
  和原生正则。
