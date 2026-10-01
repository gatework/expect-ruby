# Ruby API

支持 Ruby 3.4+ 和 Linux/macOS。加载入口为 `require "expect/pty"`，独立流过滤器可加载 `expect/redactor`。
`Expect` 是模块；`Expect::Session` 是公开的真实会话。工厂、回调、链式方法与 `Result#session` 使用同一个 Session。

## 创建与关闭

`Expect.spawn(*command, env: {}, chdir: nil, raw: false, graceful: false, **settings)` 创建并启动 PTY。
`settings` 是下文列出的六个显式会话关键字的统称，并非任意配置 Hash。需要预设终端时先 `Expect::Session.new(**settings)`，
通过 `session.slave` 使用原生终端方法，再调用 `session.spawn(*command, env: {}, chdir: nil, raw: false)`。
Session 构造器不接收命令或操作参数。同一会话只能启动一次。

单字符串遵循 Ruby 的自动 shell 语义；多个独立参数按 argv 执行。外部输入应作为独立参数传入。
启动失败抛出 `Expect::SpawnError`；工厂失败时回收尚未交付的会话。

`Expect.open(io, writer: io, own: false, graceful: false, **settings)` 适配真实可 select 的 IO，默认借用。
`own: true` 接管关闭责任，包括初始化中已知设置的非法值导致的失败；未知关键字在 Ruby 方法入口拒绝，此时不接管 IO。
`spawn`、`open` 无块时返回 Session，有块时返回块结果并确保按 `graceful:` 关闭；非局部返回也清理。
清理中的 StandardError 不覆盖本次作用域已有的主异常；没有主异常时照常传播。新发生的 Interrupt/SystemExit 不会被清理包装吞掉。

`close(graceful: false)` 最终硬关闭兜底，返回 nil；`soft_close(timeout: 15, term_timeout: 1)` 收取尾部、关闭句柄并最多发送 TERM；
`hard_close(timeout: 0.2)` 关闭句柄后分阶段等待、TERM、KILL。后两者和 `wait(timeout: nil)` 返回真实 `Process::Status` 或 nil。
借用 IO 不随会话关闭。输入 EOF、IO 关闭与子进程退出分别由 `eof?`、`closed?`、`process_status` 表示。

## 匹配与回调

`session.expect(*patterns, timeout: session.timeout, deadline: nil, consume: true, reset_timeout_on_read: false)` 返回不可变 `Expect::Result`。
`Expect.expect` 使用相同操作关键字，另加 `from:` 指定默认来源；其 timeout 默认 nil。模式为 String、Regexp、`:eof` 或 `:timeout`，
位置模式与声明块不能混用。`number` 为从 1 开始的文本模式序号或 nil，事件声明也占序号；使用 `matched?` 判断成功。

```ruby
result = session.expect(timeout: 3) do |patterns|
  patterns.on("name: ") do |source|
    source.puts("Ruby")
    Expect.continue
  end
  patterns.on(/hello (\w+)/)
end
result => { number:, captures: }
```

无参数声明块在 PatternList 上运行，直接调用 `on`、`eof`、`timeout`；有参数块保留调用者 self。
注册完成后模式与分组冻结，借用的会话与回调不冻结。相邻同来源组按对象身份及顺序合并，优先级为组、会话、模式；不按文本位置重排。
`on`、`eof` 回调接收 Session；`timeout` 接收全部活跃来源。只有 `Expect.continue(reset_timeout: true)` 的控制符使等待继续，
`reset_timeout: false` 保持原相对期限。全部 EOF 后直接返回 EOF；已处理的来源不再参与超时。

`consume: false` 仅在本轮保留完整匹配缓冲；继续但不改变缓冲的模式暂停到输入变化，避免反复触发。
`reset_timeout_on_read: true` 使每次读取重置本轮相对期限。`deadline` 是单调时钟绝对秒数，不被输入或回调延长。
IO 期限不打断用户代码或单次正则；不可信正则应使用 Ruby `Regexp` 自身的 timeout。

Result 字段为 `number`、`error`、`match`、`before`、`after`、`session`、`captures`。对象、文本及捕获数组均不可变，未参与捕获为 nil。
错误为 nil、`:timeout`、`:eof` 或原始 IO 异常；来源会话与异常不复制、不冻结。使用 `matched?`、`timeout?`、`eof?` 查询，
使用 `to_h`、位置/键模式解构或 `with` 构造新结果；没有字段 writer 或 `to_a`。
会话的 `last_result`、`before`、`after`、`match`、`match_number`、`captures`、`error` 读取最近结果。

匹配、捕获按原始字节保存；文本显示时先 `dup` 再 `force_encoding`。固定 UTF-8 正则等待尾部字符收齐，非法编码抛出 EncodingError。
成功默认消费匹配前缀，超时保留缓冲，EOF 将余下内容放入 before 并清空缓冲。EOF 不表示子进程已经退出。

## 会话属性与读写

不提供全局配置或配置对象。构造器、工厂显式接受以下设置，会话可通过同名 reader/writer 修改；非法更新保留原值。

| 设置 | 默认值 | 语义 |
|---|---|---|
| timeout、write_timeout | nil | 非负有限秒数；nil 无限，0 非阻塞尝试 |
| buffer_limit | nil | 正整数尾部字节上限，nil 无限 |
| logger | nil | 借用 Ruby Logger 的 add/debug? 协议 |
| transcript | nil | 借用 write 协议，记录真实接收字节 |
| outputs | [] | 复制可写目标数组，原样转发接收字节 |

操作参数 `raw`、`consume`、`reset_timeout_on_read`、`graceful` 不持久化为会话设置。
`buffer` 返回副本，`buffer=` 复制并应用上限，`clear_buffer` 移交并清空缓冲；`buffer_discarded_bytes` 累计窗口裁剪量，匹配消费不计入。

`write(*objects)` 按 to_s 写字节并返回字节数，`<<` 返回 Session，`puts` 遵循 Ruby IO 换行与数组规则并返回 nil。
`send_slow(*objects, delay:)` 按字符延迟发送并收取回复。背压超时抛出 `Expect::WriteTimeout`，`bytes_written` 仅标识本次调用已确认进度，
嵌套写入异常放在 cause。成功短写不受 write_timeout 的总耗时限制。
`to_io`、`writer`、`slave` 暴露句柄；`pid`、`command`、`tty_name`、`fileno`、`tty?`、`alive?`、`exit_code` 查询会话属性。
终端直接使用 `session.to_io.console_mode`、`echo=`、`winsize` 等 Ruby io/console 接口，没有 stty 或窗口尺寸包装方法。

## 诊断、脱敏与转接

`logger=` 接收 nil 或支持 `add` / `debug?` 的对象，直接兼容 Ruby Logger 及符合此协议的 ActiveSupport logger；不依赖 ActiveSupport。
Logger 自身控制级别和格式。INFO 记录生命周期/匹配，DEBUG 增加收发字节；`add` 接收冻结事件 Hash
`{ event:, pid:, fd:, message: }` 和 progname `"Expect"`，message 字符串也冻结。

`transcript=` 接收 nil 或 writer；路径打开、权限和关闭由调用方通过 File.open 管理，不接收路径或 callable。
`write_transcript(*objects)` 补写接收记录并返回 nil；不发送到子进程。writer 必须返回实际接受的正整数字节数，支持短写。
logger、transcript、outputs 一律借用，显式关闭冲刷过滤尾部，但不会关闭这些目标。

`redact(*secrets)` 追加非空字符串，仅过滤 transcript 和诊断，不更改匹配、Result 或 outputs。
`Expect::Redactor` 提供 `append`、`finish(partial: true)`、`patterns=` 和完整文本类方法 `redact`；流尾部默认隐藏疑似秘密前缀。

`outputs=` 校验并复制可写目标数组，读取返回副本；`$stdout` 与其他 writer 一样显式加入。
`Expect.interconnect(*sources, timeout: nil)` 按 outputs 转接，返回停止来源或在总期限到达时返回 nil。
`on_sequence(String/Regexp/:eof) { ... }` 注册无参数回调，未给块或返回 nil/false 停止，其余值继续。
`pending_output?` 表示尚未交付数据；再次转接同源会话继续发送，不重放成功前缀；更换 outputs 不改变已排队字节的目标。
同源递归转接抛出 ReentrancyError；转义回调可嵌套匹配，所有来源状态按对象身份隔离。

`interact(input: $stdin, escape: nil, output: nil, timeout: nil, raw: true)` 临时建立双向转接，退出后恢复 outputs、转义和本地终端模式。
`output: nil` 使用默认输出，`escape: nil` 不注册退出序列；显式 false 不是缺省值，非法输出或转义会在转发前报错。
`raw: false` 将终端设置留给调用方。transcript、logger 及自定义 writer 同步执行，应及时返回。

`Expect.monotonic` 读取单调时钟，`Expect.duration` 校验秒数，`Expect.readable_sessions(*sources, timeout: 0)` 返回就绪来源。
Matcher、Relay、资源账本和标为 `@api private` 的 Session 协作方法不是用户契约。RBS 覆盖公开声明；`rbs validate` 不验证 Ruby 方法体。
