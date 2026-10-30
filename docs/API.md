# Ruby API

支持 Ruby 4.0.6+ 和 Linux/macOS。加载入口为 `require "expect/pty"`，独立流过滤器可加载 `expect/redactor`。
`Expect` 是模块；`Expect::Session` 是公开的真实会话。工厂、回调、链式方法与 `Result#session` 使用同一个 Session。

## 创建与关闭

`Expect.spawn(*command, env: {}, chdir: nil, raw: false, shell: false, graceful: false, **settings)` 创建并启动 PTY。
`settings` 是下文列出的六个显式会话关键字的统称，并非任意配置 Hash。需要预设终端时先 `Expect::Session.new(**settings)`，
通过 `session.slave` 使用原生终端方法，再调用 `session.spawn(*command, env: {}, chdir: nil, raw: false, shell: false)`。
Session 构造器不接收命令或操作参数。同一会话只能启动一次。

命令默认直接按可执行文件名与 argv 执行，单字符串也只作为文件名。需要 shell 语法时显式指定
`shell: true`，仅接受一个字符串并交给 `/bin/sh -c`；外部输入应作为独立 argv 传入。
启动失败抛出 `Expect::SpawnError`；系统错误的 `errno` 和 `cause` 保存错误编号与相应 `SystemCallError`。
通过 `error.cause.is_a?(Errno::ENOENT)` 判断原因，外层仍为 SpawnError。非系统错误保留描述，不按任意类名恢复异常。
工厂失败时回收尚未交付的会话。

`Expect.open(io, writer: io, own: false, graceful: false, **settings)` 适配真实可 select 的 IO，默认借用。
`own: true` 接管关闭责任，包括初始化中已知设置的非法值导致的失败；未知关键字在 Ruby 方法入口拒绝，此时不接管 IO。
`spawn`、`open` 无块时返回 Session，有块时返回块结果并确保按 `graceful:` 关闭；非局部返回也清理。
工厂块正常返回时才执行 graceful 读尾；异常、线程取消以及 return/break/throw 等非局部退出直接硬关闭，避免读尾延迟退出。
块正常返回 nil 或 false 仍属于正常完成；调用方 rescue 中已处理的异常不影响此判断。
清理中的 StandardError 不覆盖本次作用域已有的主异常；没有主异常时照常传播。新发生的 Interrupt/SystemExit 不会被清理包装吞掉。

`close(graceful: false)` 最终硬关闭兜底，返回 nil；`soft_close(timeout: 15, term_timeout: 1)` 收取尾部、关闭句柄并最多发送
TERM；
`hard_close(timeout: 0.2)` 关闭句柄后分阶段等待、TERM、KILL。后两者和 `wait(timeout: nil)` 返回真实 `Process::Status` 或
nil。
直接 `soft_close` 在读尾、日志或输出交付失败时仍尝试软关闭并保留原始异常；失败路径跳过剩余自然退出等待，
尤其不会因 `timeout: nil` 阻塞异常传播，TERM 阶段仍使用 `term_timeout`，不会升级为 KILL。参数校验失败不关闭会话。
借用 IO 不随会话关闭。输入 EOF、IO 关闭与子进程退出分别由 `eof?`、`closed?`、`process_status` 表示。

## 匹配与回调

`session.expect(*patterns, timeout: session.timeout, deadline: nil, consume: true, reset_timeout_on_read: false, search_window: nil)` 返回不可变
`Expect::Result`。
`Expect.expect` 使用相同操作关键字，另加 `from:` 指定默认来源；其 timeout 默认 nil。模式为 String、Regexp、`:eof` 或
`:timeout`，
位置模式与声明块不能混用。`match_number` 为从 1 开始的文本模式序号或 nil，事件声明也占序号；使用 `matched?` 判断成功。

```ruby
result = session.expect(timeout: 3) do |patterns|
  patterns.on("name: ") do |source|
    source.puts("Ruby")
    Expect.continue
  end
  patterns.on(/hello (\w+)/)
end
result => { status: :matched, match_number:, captures: }
```

无参数声明块在 PatternList 上运行，直接调用 `on`、`eof`、`timeout`；有参数块保留调用者 self。
注册完成后模式与分组冻结，借用的会话与回调不冻结。相邻同来源组按对象身份及顺序合并，优先级为组、会话、模式；不按文本位置重排。
`on`、`eof` 回调接收 Session；`timeout` 接收全部活跃来源。只有 `Expect.continue(reset_timeout: true)` 的控制符使等待继续，
`reset_timeout: false` 保持原相对期限。全部 EOF 后直接返回 EOF；已处理的来源不再参与超时。

`consume: false` 仅在本轮保留完整匹配缓冲；继续但不改变缓冲的模式暂停到输入变化，避免反复触发。
回调中的嵌套等待实际读入新字节时，即使缓冲内容与之前相同也会恢复匹配；仅同值赋回缓冲不算新输入。
`reset_timeout_on_read: true` 使每次读取重置本轮相对期限。`deadline` 是单调时钟绝对秒数，不被输入或回调延长。
IO 期限不打断用户代码或单次正则；不可信正则应使用 Ruby `Regexp` 自身的 timeout。

`search_window` 为正 Integer 字节数或 nil，只作用于本次等待，包括 Responder 的完成模式与应答规则。
nil 保留全缓冲扫描；指定时，字符串和正则只搜索最新的尾部窗口。它不限制接收缓冲内存，也不丢弃旧字节，
结果的 before/after 和消费范围仍相对于完整缓冲。长输出建议同时按业务需要设置 `buffer_limit` 并用 transcript 保存全文。
窗口必须容纳完整提示与跨读取片段，窗口之外的模式可能错过；正则的锚点、前瞻和后顾只看到独立窗口。
固定 UTF-8 正则跳过边界切开的合法首字符，等待合法未完成尾字符；窗口内非法字节及 EOF 未完成字符仍报错。
二进制正则按原始字节匹配。

Result 的 `inspect` 与 `to_s` 仅显示匹配序号和错误状态，不打印原始文本、异常消息或来源对象。
需要原始结果时显式读取字段；`redact` 不改变这些字段。
Result 字段按顺序为 `status`、`match_number`、`error`、`match`、`before`、`after`、`session`、`captures`。
状态为 `:matched`、`:timeout`、`:eof` 或 `:error`；`error` 只保存原始异常或 nil，等待超时和 EOF 均不是异常。
使用 `matched?`、`timeout?`、`eof?`、`error?` 查询。仅匹配状态具有正整数编号和字符串 match（包括零宽匹配的空串）；
其余状态没有编号、match、after 或捕获，只有 `:error` 状态携带异常。参数、编码与回调异常仍按原规则直接抛出。

对象、文本及捕获数组均不可变，未参与的捕获为 nil；来源会话与异常不复制、不冻结。
使用 `to_h`、位置/键模式解构或 `with` 构造新结果；构造必须指定 status，new、[]、with 都拒绝矛盾状态与非字符串文本。
没有字段 writer、旧 number 或 to_a。会话的 `last_result`、`before`、`after`、`match`、`match_number`、`captures`、`error`
读取最近结果；最近等待状态使用 `last_result.status`，与输入 EOF、IO 关闭、进程状态分别查询。

匹配、捕获按原始字节保存；文本显示时先 `dup` 再 `force_encoding`。固定 UTF-8 正则等待尾部字符收齐，非法编码抛出
EncodingError。
成功默认消费匹配前缀，超时保留缓冲，EOF 将余下内容放入 before 并清空缓冲。EOF 不表示子进程已经退出。

## 自动应答

已有 `PatternList#on` 配合 `Expect.continue` 可手写应答循环。批量脚本使用 `Expect::Responder` 复用规则，
不必每条命令重新拼接回调；普通 `expect` 的声明优先级保持不变。

```ruby
rules = Expect::Responder.new do |responses|
  responses.on("Apply change? [y/N] ", reply: "y\n", limit: 5)
  responses.on("--More--", reply: " ", limit: 100)
  responses.on(/Repeat code (\d+): /, limit: 1) { |session| session.puts(session.captures.first) }
end.freeze

# 登录并收取设备初始提示后，再逐条发送配置。
commands.each do |command|
  session.puts(command)
  result = rules.expect(session, "device>", timeout: 30, deadline: Expect.monotonic + 60)
  raise "command incomplete: #{result.status}" unless result.matched?
end
```

- `on(pattern, reply: nil, limit: nil)` 只接受非空 String 或 Regexp；必须提供 String 回复或动作块，二者互斥。
  静态字符串复制并冻结，块收到带 `before`、`match`、`captures` 的 Session；块返回值忽略，应答后继续等待。
- `reply` 原样发送，行确认自行包含 `\n` 或 `\r`，分页可发送空格；空回复合法但不产生字节。
  不内置通用“全部确认”规则，调用方应按目标设备及业务选择精确提示和回复。
- `expect(session, *patterns, timeout: session.timeout, deadline: nil, search_window: nil)` 仅处理一个 Session；也可使用与 `expect` 相同的
  PatternList 块声明完成模式、EOF 和 timeout 回调。位置参数模式与块不能同时提供。
- 自动应答与完成模式按最早的字节位置处理；同位置时完成模式先于应答，多个应答按声明顺序。
  不按正则长度推测未完成提示，不在未知提示上猜测回复。仅将成功匹配的文本视为完成，业务错误输出需由调用方注册为终止模式并检查。
- 每条规则的 `limit` 是一次等待内的最大应答次数，必须为正 Integer，nil 不限；每次调用独立计数。
  超限或正则匹配空文本时，抛出 `Expect::Responder::ResponseError`，且不执行本次应答。触发该异常的匹配已经按普通匹配语义消费，
  未读尾部留在会话中。应答发送失败原样传播，不自动重试可能已经部分交付的确认。
- 应答不重置相对 timeout，deadline 仍是不可延长的总期限；沿用 Matcher 的协作式期限检查。
  动作块、单次正则计算和写入不由匹配期限强行中断；应为会话配置 `write_timeout`。
  timeout 和 EOF 返回普通 Result，默认未知提示等到超时。显式完成回调仍遵循 `Expect.continue` 契约。
- 中途应答消费 `before` 和 `match`；最后 Result 仅表示完成、EOF 或超时，不汇总整条脚本输出。
  需要全文时在发送命令前设置 `session.transcript`；逐段展示可在动作块打印 `before/match`，完成后打印最终 `before`。
  完成后的尾部保留给下一轮。发送秘密前调用 `session.redact(secret)`，回复会经过正常写入诊断，规则摘要不展示内容。
- 注册阶段不读写 IO；每次等待快照规则，回调中的规则修改仅影响以后等待。不接管会话资源，
  不保证同一会话并发操作安全；设备的 SSH 登录和配置成功判定仍属于调用方。

本地设备模拟见 `examples/auto_response.rb`；`examples/ssh_auto.rb` 接入精确规则并保留分段输出和完整 transcript。

## 会话属性与读写

不提供全局配置或配置对象。构造器、工厂显式接受以下设置，会话可通过同名 reader/writer 修改；非法更新保留原值。

| 设置                   | 默认值 | 语义                                 |
|------------------------|--------|--------------------------------------|
| timeout、write_timeout | nil    | 非负有限秒数；nil 无限，0 非阻塞尝试 |
| buffer_limit           | nil    | 正整数尾部字节上限，nil 无限         |
| logger                 | nil    | 借用 Ruby Logger 的 add/debug? 协议  |
| transcript             | nil    | 借用 write 协议，记录真实接收字节    |
| outputs                | []     | 复制可写目标数组，原样转发接收字节   |

操作参数 `raw`、`consume`、`reset_timeout_on_read`、`graceful` 不持久化为会话设置。
`buffer` 返回副本；只检查容量时使用 `buffer_bytesize`，以常数时间取得当前未消费主缓冲的字节数，不复制正文、不读取 IO，也不包含 Relay 待写数据或历史窗口。`buffer=` 复制并应用上限，`clear_buffer` 移交并清空缓冲；`buffer_discarded_bytes` 累计窗口裁剪量，匹配消费不计入。
显式替换/清空、实际裁剪和消费输入会清除正则转义历史；非消费匹配、未裁剪的等待与内部缓冲交接保持连续历史。
正则转接历史默认保留至多 65,536 字节，设置 `buffer_limit` 后采用该上限。存在固定 UTF-8 正则时，历史预算至少为 3 字节，以保留四字节字符尚未接收完整的前缀；这不扩大普通匹配缓冲的上限，也不延迟协议转发。

`write(*objects)` 按 to_s 写字节并返回字节数，`<<` 返回 Session，`puts` 遵循 Ruby IO 换行与数组规则并返回 nil。
`send_slow(*objects, delay:)` 按字符延迟发送并收取回复。背压超时抛出 `Expect::WriteTimeout`，`bytes_written` 仅标识本次调用已确认进度，
嵌套写入异常放在 cause。成功短写不受 write_timeout 的总耗时限制。
对象转换、发送诊断或背压读取的回调若关闭会话，后续写入抛出 IOError；借用 IO 仍归调用方所有，空写入同样检查关闭状态。
`send_slow` 的进度累计本次调用中此前完整字符与失败字符实际接受的字节；转换对象和记录回复的内层写入进度不计入。
首字符 write 的异常无需修正进度时保留原对象；需要累计或排除内层进度时包装并保留 cause。
`to_io`、`writer`、`slave` 暴露句柄；`pid`、`command`、`tty_name`、`fileno`、`tty?`、`alive?`、`exit_code` 查询会话属性。
终端直接使用 `session.to_io.console_mode`、`echo=`、`winsize` 等 Ruby io/console 接口，没有 stty 或窗口尺寸包装方法。

## 诊断、脱敏与转接

`logger=` 接收 nil 或支持 `add` / `debug?` 的对象，直接兼容 Ruby Logger 及符合此协议的 ActiveSupport logger；不依赖
ActiveSupport。
Logger 自身控制级别和格式。INFO 记录生命周期/匹配，DEBUG 增加收发字节；`add` 接收冻结事件 Hash
`{ event:, pid:, fd:, message: }` 和 progname `"Expect"`，message 字符串也冻结。

`transcript=` 接收 nil 或 writer；路径打开、权限和关闭由调用方通过 File.open 管理，不接收路径或 callable。
`write_transcript(*objects)` 补写接收记录并返回 nil；不发送到子进程。writer 必须返回实际接受的正整数字节数，支持短写。
调用开始时没有 transcript 则不转换参数；对象的 `to_s` 若切换目标，整条补记及脱敏尾部使用转换完成后的目标，禁用目标则不写入。
logger、transcript、outputs 一律借用，显式关闭冲刷过滤尾部，但不会关闭这些目标。

`redact(*secrets)` 追加非空字符串，仅过滤 transcript 和诊断，不更改匹配、Result 或 outputs。
DEBUG 关闭期间仍推进分片脱敏，但这些字节不会在重新启用后补记。转接到 Session 的发送诊断仅记录底层接受的片段，
与直接 write 共用过滤状态；诊断失败不回退转接进度，嵌套 WriteTimeout 的原始进度由 cause 保留。
`Expect::Redactor` 提供 `append`、`finish(partial: true)`、`patterns=` 和完整文本类方法 `redact`；流尾部默认隐藏疑似秘密前缀。

`outputs=` 校验并复制可写目标数组，读取返回副本；`$stdout` 与其他 writer 一样显式加入。
`Expect.interconnect(*sources, timeout: nil)` 按 outputs 转接，返回停止来源或在总期限到达时返回 nil。
`on_sequence(String/Regexp/:eof) { ... }` 注册无参数回调，未给块或返回 nil/false 停止，其余值继续。
`pending_output?` 表示尚未交付数据；再次转接同源会话继续发送，不重放成功前缀；更换 outputs 不改变已排队字节的目标。
同源递归转接抛出 ReentrancyError；转义回调可嵌套匹配，所有来源状态按对象身份隔离。
接收字节交付期间，logger/transcript/outputs 的回调不能递归读取同一会话的新输入，否则抛出 ReentrancyError；
匹配已有缓冲及读取独立会话仍可用。正数转接总期限会在扫描、继续回调返回后及读取每个就绪来源前检查；接收回调耗尽预算后不再读取后续来源。
已读分片的交付仍完整完成，零超时仍处理缓冲并首次轮询。

`interact(input: $stdin, escape: nil, output: nil, timeout: nil, raw: true)` 临时建立双向转接，退出后恢复
outputs、转义和本地终端模式。
各项恢复都会尝试；恢复中的常规错误不会覆盖已有的业务异常，没有业务异常时仍报告恢复错误。
`output: nil` 使用默认输出，`escape: nil` 不注册退出序列；显式 false 不是缺省值，非法输出或转义会在转发前报错。
`raw: false` 将终端设置留给调用方。transcript、logger 及自定义 writer 同步执行，应及时返回。

`Expect.monotonic` 读取单调时钟，`Expect.duration` 校验秒数，`Expect.readable_sessions(*sources, timeout: 0)` 返回就绪来源。
时间参数只接受有限实数 Numeric 或 nil，拒绝字符串、Complex、布尔值及非有限数，非法值统一抛 ArgumentError。
相对期限必须非负，deadline 允许负数表示已到期。
Matcher、Relay、资源账本和标为 `@api private` 的 Session 协作方法不是用户契约。RBS 覆盖公开声明；`rbs validate` 不验证 Ruby
方法体。
