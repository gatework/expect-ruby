# Ruby API

支持 Ruby 3.4+ 和 Linux/macOS。加载入口为 `require "expect/pty"`，独立流过滤器可加载 `expect/redactor`。

## 创建与关闭

`Expect.spawn(*command, env: {}, chdir: nil, **configuration)` 创建并启动 PTY；`Expect.new` 可先创建 PTY，再通过实例 `spawn` 启动。
单字符串遵循 Ruby 的自动 shell 语义（含 shell 元字符时可能交给 shell）；多个独立参数按 argv 执行。
外部输入应作为独立参数传入，避免拼接进单字符串命令。启动失败抛出 `Expect::SpawnError`。

`Expect.open(io, writer: io, own: false, **configuration)` 适配真实可 select 的 IO。默认借用；`own: true` 接管关闭责任，
包括初始化失败。类级 `spawn`、`open` 无块时返回 Expect，有块时返回块结果并确保关闭。非局部返回也清理。

`close(graceful: graceful_close?)` 最终硬关闭兜底，返回 nil；`soft_close(timeout: 15, term_timeout: 1)` 收取尾部、关闭句柄并最多发送 TERM；
`hard_close(timeout: 0.2)` 关闭句柄后分阶段等待、TERM、KILL。后两者和 `wait(timeout: nil)` 返回真实 `Process::Status` 或 nil。
借用 IO 不随会话关闭。输入 EOF、IO 关闭与子进程退出分别由 `eof?`、`closed?`、`process_status` 表示。

## 匹配与回调

`expect(*patterns, timeout:, deadline:)` 统一返回 `Expect::Result`；`number` 为从 1 开始的文本模式序号或 nil。
使用 `matched?` 判断匹配成功，Result 对象本身始终为真值。
类方法增加 `from:` 指定默认来源。模式为 String、Regexp、`:eof` 或 `:timeout`，位置模式与声明块不能混用。

```ruby
result = session.expect(timeout: 3) do |patterns|
  patterns.on("name: ") do |connection|
    connection.puts("Ruby")
    connection.continue
  end
  patterns.on(/hello (\w+)/)
end
result => { number:, captures: }
```

无参数声明块在 PatternList 上运行，直接调用 `on`、`eof`、`timeout`；有参数块保留调用者 self。
注册完成后模式与分组冻结，再次注册抛出 FrozenError；借用的会话与回调不被冻结。
`on`、`eof` 的回调接收外层 Expect；`timeout` 接收全部活跃来源的数组。
只有 `Expect.continue(reset_timeout: true)` 或实例 `continue` 的控制符使等待继续；`reset_timeout: false` 保持原相对期限。
`deadline` 是单调时钟绝对秒数，不被输入或回调延长。IO 期限不会强行中断用户回调或单次正则计算。

Result 字段为 `number`、`error`、`match`、`before`、`after`、`session`、`captures`。对象、字符串及捕获数组均不可变，未参与捕获的组为 nil。
`matched?`、`timeout?`、`eof?` 查询结果。错误为 nil、`:timeout`、`:eof` 或原始 IO 异常；原始异常与来源会话不冻结。
使用 `to_h`、位置/键模式解构或 `with` 构造新结果；没有字段 writer 或 `to_a`。
`last_result` 以及会话上的 `before`、`after`、`match`、`match_number`、`captures`、`error` 读取最近结果。

匹配和捕获按原始字节保存；文本显示时先 `dup` 再 `force_encoding`。固定 UTF-8 正则等待尾部字符收齐，非法编码抛出 EncodingError。

## 配置与读写

`Expect.configuration` 返回冻结默认配置，`Expect.configure(**options) { |config| ... }` 发布新快照；失败不发布部分设置。
每个会话拥有独立配置，可以通过同名 reader/writer 修改。未知配置键抛出 ArgumentError。

| 属性 | 默认值 | 语义 |
|---|---|---|
| timeout、write_timeout | nil | 非负有限秒数；nil 无限，0 非阻塞尝试 |
| buffer_limit | nil | 正整数尾部字节上限，nil 无限 |
| debug_level | 0 | 0 关闭，1 生命周期，2 收发字节，3 缓冲 |
| raw_pty、preserve_buffer、log_stdout | false | 子终端 raw、匹配后保留缓冲、stdout 转发 |
| log_listeners、raw_terminal | true | 监听器转发、人工接管时设置本地 raw |
| reset_timeout_on_read、graceful_close | false | 输入刷新相对期限、通用 close 先软关闭 |

布尔项只提供 `name?` 和 `name=`，赋值遵循 Ruby 真值规则。`buffer` 返回副本，`buffer=` 复制并应用上限，`clear_buffer` 移交并清空缓冲；
`buffer_discarded_bytes` 累计窗口裁剪量，匹配消费不计入。

`write(*objects)` 按 to_s 写字节并返回字节数，`<<` 返回 Expect，`puts` 遵循 Ruby IO 换行与数组规则并返回 nil。
`send_slow(*objects, delay:)` 按字符延迟发送并收取回复。背压超时抛出 `Expect::WriteTimeout`，`bytes_written` 标识已确认进度。
`to_io`、`writer`、`slave` 暴露底层句柄；`pid`、`command`、`tty_name`、`fileno`、`tty?`、`alive?`、`exit_code` 查询会话属性。
`stty(*modes)` 查询/设置终端模式；`winsize` 和 `winsize=` 使用 `[行数, 列数]`。

## 日志、脱敏与转接

`log_to(target, mode: "a")` 接收路径或可写目标，也可只给块。路径以私有权限打开并取得关闭责任；IO/块只借用。
`log_output=` 更换目标或设 nil 停止；`write_log` 补写日志而不发送到子进程。IO writer 必须返回实际接受的字节数，支持短写；
日志块的返回值不控制匹配。日志记录真实读取，不因匹配/转接重复记录。

`diagnostic_output=` 接收 info/debug Logger 协议、可写对象、回调或 nil。回调接收冻结事件 Hash：`event`、`level`、`pid`、`fd`、`message`。
`redact(*secrets)` 注册非空字符串，仅过滤日志和诊断，不更改匹配或协议字节。`Expect::Redactor` 提供 `append`、`finish(partial: true)`、
`patterns=` 和完整文本类方法 `redact`；流尾部默认隐藏疑似秘密前缀。

`listeners=` 校验并复制可写目标数组，`listeners` 返回副本。`Expect.interconnect(*sources, timeout:)` 按监听关系转接，
返回停止来源或在总期限到达时返回 nil。`on_sequence(String/Regexp/:eof) { ... }` 注册无参数回调，nil/false 停止，其余值继续。
`pending_output?` 表示尚未交付数据；再次转接同源会话继续发送，不重放成功前缀。同源递归转接抛出 ReentrancyError，转义回调可以嵌套匹配。

`interact(input: $stdin, escape: nil, output: nil, timeout: nil)` 临时建立双向转接，退出后恢复监听关系和本地终端模式。
日志、诊断及自定义 writer 回调同步执行，应及时返回。

`Expect.monotonic` 读取单调时钟，`Expect.duration` 校验秒数，`Expect.readable_sessions(*sources, timeout: 0)` 返回就绪来源。
内部 Session、Matcher、Relay 和资源账本不属于用户 API。RBS 覆盖公开声明与协作协议；`rbs validate` 不验证 Ruby 方法体。
