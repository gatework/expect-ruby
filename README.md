# expect-ruby

[![CI](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml)

用 Ruby 自动操作交互式程序：启动拥有控制终端的子进程，等待文本或正则，发送输入，处理超时、EOF 和回调，也能接管已有
IO、同时监听多个会话和转接人工交互。交互能力参考 [Expect.pm](https://github.com/jacoby/expect.pm)，接口采用 Ruby
的属性、关键字参数和代码块。

要求 **Ruby 3.4+、POSIX 系统（Linux/macOS）**。运行时仅使用 Ruby 标准库，其中可独立安装的 gem 已在 gemspec 中声明，由
RubyGems/Bundler 解析。推荐入口 **`require "expect/pty"`**；本项目提供独立的 `Expect` 模块和 `Expect::Session` 会话，不修改标准库的
`IO#expect`。

源码中的解释性注释主要使用中文；欢迎用中文或英文提交 issue 和 PR，参与方式见 [贡献指南](CONTRIBUTING.md)。

## 安装和运行

项目和仓库名为 `expect-ruby`，Gem 名为 `expect-pty`。在应用的 Gemfile 中添加以下内容，然后运行 `bundle install`：

```ruby
gem "expect-pty", "~> 0.7.1", require: "expect/pty"
```

也可直接执行 `gem install expect-pty`。需要跟随开发分支时，可从 GitHub 安装：

```ruby
gem "expect-pty", git: "https://github.com/gatework/expect-ruby.git", branch: "main", require: "expect/pty"
```

本地开发可改用 `gem "expect-pty", path: "/path/to/expect-ruby", require: "expect/pty"`，也可在源码目录构建安装：

```sh
mkdir -p tmp
gem build expect-pty.gemspec --output tmp/expect-pty-0.7.1.gem
gem install ./tmp/expect-pty-0.7.1.gem
```

```ruby
require "expect/pty"

Expect.spawn("/bin/sh", "-i") do |shell|
  shell.puts("printf 'hello ruby\\n'")
  if shell.expect(/^hello ruby\r?$/, timeout: 3).matched?
    puts shell.match
  else
    warn shell.error
  end
  shell.puts("exit")
  shell.soft_close(timeout: 2)
end
```

块返回其执行结果，退出时关闭会话并回收子进程，异常和 `break` 也执行清理。构造或启动失败时同样释放已创建的资源；清理中的
`StandardError` 不替换本次作用域已有的主异常，没有主异常时仍传播；清理中新发生的 `Interrupt` / `SystemExit` 不吞掉。
无块形式需用 `ensure` 显式调用 `close`。`Expect::Session.new` 可以先创建 PTY，通过 `slave.echo=` /
`slave.winsize=` 设置终端，然后调用 `session.spawn`。工厂返回、回调参数和 `Result#session` 都是同一个真实 Session。

多个命令参数原样传给 Ruby `exec`；单个命令字符串使用 Ruby 的 shell 语义。不可信参数应使用独立参数形式。支持
`env: { "NAME" => "value" }` 和 `chdir: "/path"`。同一会话只能启动一次，启动失败抛出 `Expect::SpawnError`。

## 会话设置与操作参数

```ruby
logger = Logger.new($stderr, level: Logger::INFO)
Expect.spawn("/bin/sh", "-i", timeout: 3, buffer_limit: 65_536,
             logger: logger, outputs: [$stdout]) do |session|
  session.timeout = 5
  session.puts("exit")
end
```

所有设置显式传给会话，不提供全局默认配置或配置基类。需要应用默认值时，由调用方保存 Hash，再用关键字展开传入。
各会话独立保存以下属性，修改不会影响其他会话；借用的 logger、transcript 和输出对象可以由调用方共享。

| 会话属性        | 默认值 | 行为                                                  |
|-----------------|--------|-------------------------------------------------------|
| `timeout`       | `nil`  | `session.expect` 的默认相对期限；`nil` 无限、`0` 轮询 |
| `write_timeout` | `nil`  | 写入遇到背压或 EINTR 时的等待期限                     |
| `buffer_limit`  | `nil`  | 匹配缓冲保留的尾部字节数；正整数或 `nil`              |
| `logger`        | `nil`  | 借用支持 `add` / `debug?` 的诊断 logger               |
| `transcript`    | `nil`  | 借用支持 `write` 的接收字节记录目标                   |
| `outputs`       | `[]`   | 原始接收字节的转发目标数组，可包含 `$stdout`          |

这些属性都有同名 reader/writer；非法赋值不改变原设置。超时必须有限且非负。输出数组在设置时复制，读取时也返回副本。

只属于一次操作的策略放在该操作的关键字中：`spawn(raw: false)` 控制子终端，`expect(consume: true,
reset_timeout_on_read: false)` 控制匹配消费和输入重置，`interact(raw: true)` 控制本地终端模式，
`close(graceful: false)` 控制清理顺序。工厂的 `graceful:` 决定块退出时的关闭策略。`Session.new` 只接收会话属性，
命令、`env:`、`chdir:` 和 `raw:` 由之后的 `session.spawn` 接收；均无旧名称别名。

## 等待和匹配

```ruby
session.expect("literal text", /value=(\d+)/, timeout: 5)
session.timeout = 5
session.expect("ready")                # 使用会话超时
session.expect("ready", timeout: nil)  # 无限等待
session.expect("ready", timeout: 0)    # 匹配现有缓冲，并最多轮询读取一次
session.expect(timeout: 1)             # 仅收集输出，直到超时或 EOF
```

字符串始终按字面匹配，包括 `"-i"`、`"-re"`、`"timeout"` 和 `"eof"`；正则直接使用 Ruby `Regexp`
。按声明顺序选择第一个能匹配的模式，不按它们在文本中的位置排序。返回不可变 `Expect::Result`，`number` 为模式的 **1
起始序号**；超时、EOF 或 IO 错误时 `number` 为 `nil`。
判断成功使用 `matched?`，不能直接判断 Result 对象的真值。超时使用单调时钟。

```ruby
result = session.expect(/value=(\d+)/, timeout: 3)
result.matched?
result.timeout?
result.eof?
result.number
result.captures
result.session
result.error # nil、:timeout、:eof 或原始 IOError / SystemCallError 对象

result => { number:, match:, captures: }
```

`Result` 使用原生 Ruby `Data`，支持 `to_h`、位置和键模式解构。结果、文本和捕获数组均为不可变快照；
来源会话与原始异常保持原对象。不提供字段写入、`to_a` 或隐式 `to_ary`。会话提供 `last_result`，以及 `match`、
`before`、`after`、`match_number`、`captures`、`error` 快捷读取方法。

成功匹配后删除匹配内容及其之前的内容，尾部留给下次匹配；超时保留缓冲，EOF 将未匹配内容放入 `before` 并清空缓冲。EOF
与子进程退出是不同事件，使用 `wait` / `process_status` 判断进程结果。底层 IO 错误保留原始异常，回调中的普通异常直接抛出。

接收缓冲、匹配和捕获值为 `ASCII-8BIT` 字节串，保留控制字符、NUL 和无效 UTF-8。固定 UTF-8
正则会等待读取末尾拆开的字符收齐后再匹配，以免尾部锚点提前命中；显示捕获内容时可 `.dup.force_encoding("UTF-8")`
。任意二进制流请用字面字符串或二进制正则 `/.../n`。固定 UTF-8 正则遇到无效数据抛出 `EncodingError`；EOF
时仍未收齐的字符也属于无效编码，匹配缓冲保留原字节供诊断或二进制匹配。缓冲上限按字节截断，应为文本设置足够的上限。

正则完全遵循 Ruby：`^` / `$` 是行锚点，`\A` / `\z` 是整个缓冲的锚点，`/m` 让点号匹配换行；不再提供全局正则模式开关。

IO 等待的 `timeout` 不会中断单次正则计算。处理用户提供的正则或不可信长输出时，应使用有限时的正则实例，例如
`Regexp.new('prompt>\\s*', timeout: 0.05)`；该限制同样适用于 `on_sequence`。正则超时原样抛出 `Regexp::TimeoutError`
，匹配缓冲保留，库不会修改进程全局 `Regexp.timeout`。`timeout: 0` 仍会匹配已有缓冲，不代表禁止正则计算。长输出可用日志保存全文，按业务需要设置
`buffer_limit` 限制匹配窗口；缩小窗口会改变 `before` 和跨窗口匹配范围。

`session.buffer_discarded_bytes` 是只读的会话累计计数，只统计 `buffer_limit` 裁剪掉的字节。
读取新数据、赋值 `buffer` 或调低上限触发裁剪时递增；成功匹配、`clear_buffer`、EOF 消费和转接交接均不计入。
关闭会话不会清零。日志在实际读取时保存完整接收内容，不受匹配窗口裁剪影响；它可按显式注册的秘密脱敏。

## 回调、事件与多会话

```ruby
session.expect(timeout: 10) do
  on(/username:\s*/i) do |connection|
    connection.puts("demo")
    Expect.continue
  end
  on(/password:\s*/i) do |connection|
    connection.puts(password)
    Expect.continue(reset_timeout: false)
  end
  on("ready>")
  eof { |connection| warn "EOF: #{connection.before}" }
  timeout { |sessions| warn "timeout: #{sessions.length} session(s)" }
end
```

回调通过闭包访问局部变量。无参数声明块在模式构建器中执行；希望保留调用方 `self` 时使用 `do |patterns|`，调用
`patterns.on(...)`。所有模式注册完成后才读取 IO；注册异常或 `break` 不消费输入。块和位置模式不能混用。注册完成后规则冻结，回调不能再向本次等待追加模式。

`Expect.continue` 继续等待并重新计时；`Expect.continue(reset_timeout: false)`
保留原期限。回调返回后若保留的期限已过，不再扫描新的文本匹配，未消费的输入留给下一次等待。无回调或返回其他值时结束本次匹配。超时回调只有返回重置计时的
`Expect.continue` 才再次等待。EOF 回调继续时移除该源并等待其余会话；已知的 EOF 仍依次派发，全部 EOF 时直接返回，期限已过时仅对剩余活跃源触发超时。

`expect` 另接受 `deadline:`，值为 `Expect.monotonic` 时钟上的绝对秒数，`nil` 表示不设总期限。总期限与普通
`timeout` 取较早者，接收重置、文本/EOF 继续及超时回调均不能延长它。同一个 deadline 可用于连续多次等待：

```ruby
deadline = Expect.monotonic + 60
session.expect("ready", timeout: 5, deadline: deadline, reset_timeout_on_read: true)
session.expect("done", timeout: 5, deadline: deadline, reset_timeout_on_read: true)
```

上例每次等待允许最多 5 秒无新输入，两次等待共用 60 秒总预算。到达总期限后返回超时，不消费已缓冲的文本或读取新数据；已经确认的
EOF 仍可派发，全部来源结束时返回 EOF。`timeout: 0`
在总期限尚未到达时仍保留一次非阻塞轮询。总期限使用协作检查，不中断正在执行的回调、同步日志或单次正则；正则完成后若总期限已到，不消费其匹配结果。它不自动传给回调中的写入或其他操作。

`eof` / `timeout` 声明会占用模式序号，但事件返回的 `number` 为 `nil`。一个等待只能注册一个超时回调；它接收
**所有仍在监听的会话**。不需要回调时，可将 `:eof` / `:timeout` 作为位置事件参数。

```ruby
Expect.expect(timeout: 5) do
  on(/ready/, from: [first, second]) { |connection| puts connection.inspect }
  on("done", from: third)
end

Expect.expect("ready", from: [first, second], timeout: 5)
```

`from:` 指定一个或多个会话；实例块默认当前会话，模块方法需提供来源。相邻且来源列表按对象身份及顺序相同的模式组成一组，按组、会话、模式顺序匹配。模块方法省略超时为无限等待。

`expect(consume: false)` 时，继续回调通常应自行消费匹配，例如 `connection.buffer = connection.after`
。如果回调没有改变缓冲，当前模式会等待缓冲变化后才重新匹配，避免反复处理同一内容。被信号中断的匹配 select/read 会自动重试，保留原期限。

## 已有 IO、写入和终端

```ruby
Expect.open(socket) do |connection|
  connection.expect("prompt>", timeout: 5)
  connection.puts("command")
end

ready = Expect.readable_sessions(first, second, timeout: 5)
```

`Expect.open` 支持可 `select` 的 File、管道、Socket 和 PTY，`writer:` 可指定独立写端。默认借用 IO，关闭会话不关闭原始 IO；
`own: true` 转移关闭责任，初始化中的属性校验失败也会释放接管的 IO。未知关键字在 Ruby 调用入口拒绝，此时不接管 IO。`StringIO`
可以用作 transcript 和 outputs，不能用作读取会话。

用于写入或转接的真实 IO 应在首次写入前设置 `io.sync = true`，并由调用方保证没有未刷新的 Ruby 写缓冲；`write_nonblock`
可能先阻塞刷新已有缓冲，这一步不受本库的 IO 等待期限控制。已有缓冲应在交付给本库前由调用方排空，库不会绕过缓冲或改变字节顺序。

`readable_sessions` 返回可读的会话对象数组，不消费数据、不包含已关闭会话、同一会话只返回一次。默认 `timeout: 0`；`nil`
无限等待。同一会话应由一个读取者驱动，多会话共同监听使用 `Expect.expect`。

| API                                                           | 行为                                        |
|---------------------------------------------------------------|---------------------------------------------|
| `write(*objects)`                                             | 通过 `to_s` 转换并写入所有字节，返回字节数  |
| `puts(*objects)`                                              | 原生 IO 风格的换行、数组递归和 `nil` 返回值 |
| `session << object`                                           | 写入并返回会话，可链式追加                  |
| `send_slow(*objects, delay:)`                                 | 每个字符之前等待指定秒数，同时收集返回数据  |
| `buffer` / `buffer=`                                          | 获取副本 / 复制字节并应用上限               |
| `clear_buffer`                                                | 清空缓冲并返回旧内容                        |
| `to_io.console_mode` / `to_io.console_mode=`                  | 原生终端模式快照与恢复                      |
| `to_io.winsize` / `to_io.winsize=`                            | 原生 `[rows, cols]` 窗口尺寸接口            |
| `slave` / `tty_name` / `to_io` / `writer` / `fileno` / `tty?` | 底层 IO 和终端信息                          |

`send_slow` 在每次写入后只检查已经可读的回复，不附加固定等待；返回时不保证收齐最后一个字符引发的回复，完整对话请继续使用
`expect`。

大块写入遇到背压时同时读取输出，避免双向传输互相阻塞。背压等待超过 `write_timeout` 抛出 `Expect::WriteTimeout`，
`error.bytes_written` 给出本次 `write` 已被底层接受的字节数；这些字节不回滚，不要从头重发整个命令。写入、等待和背压读取中的
`EINTR` 均保留原期限重试。控制字符可直接发送，例如 `session.write("\x03")`，其信号作用取决于终端设置。`send`、`public_send`、
`__send__` 保留 Ruby 反射语义。

`write_timeout` 是背压相关期限：持续成功的正数短写不会因为总耗时超过它而失败，也不会强行打断同步用户代码。
它与匹配的 `timeout/deadline`、整次 `interconnect` 的总 `timeout` 分别计算。非空写入要求底层返回实际接受的正整数字节数，
且不能超过本次片段长度；非法计数立即抛出 `IOError`，空写入仍返回 0。

终端操作直接使用 Ruby `io/console`：例如 `session.to_io.echo = false`、`session.to_io.winsize = [24, 80]`。
需要作用域恢复时使用原生 `raw` / `cooked` 块；本库不启动 `stty` 子进程。

## 诊断、接收记录与人工交互

```ruby
require "logger"

logger = Logger.new($stderr, level: Logger::DEBUG)
File.open("session.log", File::WRONLY | File::CREAT | File::APPEND, 0o600) do |transcript|
  Expect.spawn("/bin/sh", "-i", logger: logger, transcript: transcript) do |session|
    session.redact(password, token) # 在首次通信前注册需要保护的原始字节
    session.outputs = [$stdout, another_session]
    session.write_transcript("annotation\n")
    session.puts("exit")
  end
end
```

三类目标职责独立：`logger` 接收结构化诊断；`transcript` 仅记录实际读取的接收字节；`outputs` 原样转发协议字节。
所有目标均由调用方创建和关闭。`transcript = nil` 停止记录，替换前先交付旧流过滤尾部；`write_transcript` 补写记录，返回
`nil`，
不发送到子进程。writer 必须返回实际接受的字节数，支持短写；路径与 callable 不会自动包装成 writer。

`logger` 采用 Ruby Logger 的 `add` / `debug?` 协议，默认 `nil` 禁用。Logger 自己决定级别、格式及输出位置；可直接注入兼容该协议的
ActiveSupport logger，本库不依赖 ActiveSupport。生命周期和匹配使用 INFO，收发字节使用 DEBUG，不生成缓冲快照诊断。
`add` 的 message 是冻结的 Hash，包含 `event`、`pid`、`fd`、`message`，其中 message 字符串也被冻结；progname 为 `"Expect"`。
自定义格式使用 Logger 的 formatter；事件不含会话对象。logger 的返回值不控制匹配。

所有会话默认没有 stdout 输出。需要显示时显式把 `$stdout` 放进 `outputs`。普通 `expect` 按读取顺序同步执行诊断、
transcript 和 outputs，目标须及时消费；匹配期限不会中断这些代码。慢目标需要独立调度时使用 `interconnect`。
记录不重复包含发送字节，但终端回显可能作为接收内容返回；敏感会话须控制回显、显示和目标文件权限。

`redact` 复制并追加非空字符串秘密，以 `[FILTERED]` 遮盖 transcript、`write_transcript` 及收发诊断，支持跨分片和重叠秘密。
匹配缓冲、Result 和 outputs 始终保留原始字节。它不推断编码、终端转义、哈希或其他变换后的秘密，也不能删除已交付的记录。

过滤器最多延迟最长秘密长度减一的尾部字节，EOF、目标替换和显式关闭时交付剩余内容；流边界的疑似秘密前缀也会遮盖。
发送与接收诊断独立保留过滤状态，因此实际写入分块可能变化。GC 兜底不调用用户代码；需显式关闭会话以交付过滤尾部，
然后由调用方关闭 transcript 和 logger。

应用需要过滤自己的日志或错误文本时，可以直接使用独立的字节过滤器，无需打开 PTY 或创建会话：

```ruby
require "expect/redactor"

safe_message = Expect::Redactor.redact(message, [password], replacement: "[REDACTED]")
filter = Expect::Redactor.new([password], replacement: "[REDACTED]")
output.write(filter.append(chunk)) # 每个输出流使用独立实例
output.write(filter.finish)
```

`patterns=` 用由非空字符串组成的数组替换后续规则，空数组表示不注册秘密；输入数组、字符串和替换标记都会复制，
无效更新不改变已有规则或暂存数据。已输出的内容不能撤回，更新后也会保留先前标记为隐藏的尾部区间。
`redact` 处理完整文本，只匹配完整秘密；`finish` 默认还隐藏未完成的秘密前缀。已确定输入完整的调用方可用
`finish(partial: false)`。连续或重叠的隐藏区间合并成一个替换标记。过滤不自动识别终端控制符或编码，过滤器本身不持有 IO，
也不负责会话作用域或异常对象的安全字段选择。该公共接口从 0.5.0 开始提供。

```ruby
session.interact(input: $stdin, escape: "\x1d", output: $stdout) # Ctrl-]

Expect.open($stdin) do |input|
  input.outputs = [session]
  session.outputs = [$stdout]
  input.on_sequence("\x1d") { false }
  Expect.interconnect(input, session, timeout: 60)
end
```

`on_sequence(sequence) { ... }` 注册字符串、原生正则或 `:eof`，通过闭包传递参数。无回调、返回 `nil` / `false` 停止，其他 Ruby
真值（包括 `0`）继续；字符串 `"EOF"` 按字面匹配。转接返回导致停止的会话，超时或所有 EOF 回调均继续时返回 `nil`。

`interconnect` 统一调度真实 IO 的非阻塞读写；慢目标不会阻止其他源前进，等待同时受总 `timeout` 和目标会话的 `write_timeout`
约束。总期限到达返回 `nil`，目标写期限先到则抛出 `WriteTimeout`。超时后的字面转义前缀只尝试非阻塞发送，不再等待下游。作为写入目标但未显式列出的
Session，背压期间读取的回复保留在其匹配缓冲；需要同时转发这些回复时，把它也传给 `interconnect`。

每个源独立保存待发送数据以及各目标的发送位置，`source.pending_output?` 表示仍有未交付内容。超时或异常后再次对同一源调用
`interconnect`，会接着发送未完成的后缀，已完成的目标不会重复接收；转义回调在前缀交付后执行。待发送数据与 `buffer`
中尚未处理的输入分开保存，修改 `outputs` 仅影响后续数据，旧数据仍发往原目标。恢复时不要把原始数据再次赋给 `buffer`
，也不要在排空旧输出前插入新的直接写入；关闭源会话会放弃其待发送数据。转接保留的输入暂不按 `buffer_limit` 裁剪，下次匹配时重新应用该上限。

自定义写入对象必须及时返回实际接受的字节数，短写入会继续发送后缀，零、负数或非法返回值抛出 `IOError`
。对象若先写入再抛错而不报告进度，库无法推断其副作用。日志、用户回调及自定义 `write` / `flush` 同步运行，应由调用方保证它们不会无限阻塞；上述
IO 期限不会强行中断这些代码。普通 `expect` 的同步 transcript 和 outputs 也不受匹配等待期限限制。

字面转义可以跨读取完整过滤，尾部留给下次调用。正则转义使用历史记录，默认最多保留最近 65,536 字节；设置 `buffer_limit`
后改用该值。正则及其锚点作用于当前历史窗口，超过窗口的跨读取正则无法匹配，已实时转发的前缀也无法撤回；零长度正则匹配抛出
`ArgumentError`。日志包括被转接过滤的转义，显式启用 `redact` 时遮盖注册秘密；在 `expect` / `interconnect` 之间切换不会重复记录。

一次转接尚未返回时，递归 `interconnect` 的来源若与活跃来源重叠，会在移动缓冲和修改发送游标前抛出
`Expect::ReentrancyError`。完全独立的来源仍可嵌套转接；`on_sequence` 中的嵌套 `expect` 及返回后再次转接仍受支持。
自定义 `write` 若已产生副作用却抛错、未返回计数，库无法推断已接受的字节数，此时不能保证恢复交付恰好一次。
这一保护不代表所有会话 API 都可以跨线程并发调用。

`interact` 默认 `raw: true`，自动设置并恢复本地输入终端模式，同时保留输出换行处理；`raw: false` 将设置交给调用方。
通用的 `interconnect` 只负责字节转发，由调用方管理终端模式。`interact` 会恢复临时 outputs 和转义设置，包括超时和异常路径。

对同一连接重复传入同一个原始输入 IO 时，`interact` 会复用输入包装器，接续上次预读的尾部。包装器由该连接持有，关闭连接时释放，但不关闭借用的原始
IO；已关闭的输入或包装器不再复用。需要跨连接共享或自行管理输入生命周期时，显式传入 `Expect.open(input)` 创建的会话。

## 软关闭、硬关闭与进程状态

```ruby
status = session.soft_close(timeout: 3, term_timeout: 1)
status ||= session.hard_close(timeout: 0.2)

session.close(graceful: true) # 先软关闭，必要时继续硬关闭
```

- `soft_close`：等待自然 EOF 并收集尾部输出，然后关闭所属 IO、等待进程退出；超时后最多发送 TERM， **不发送 KILL**。`timeout:`
  是自然退出阶段的期限（默认 15 秒），`term_timeout:` 是发 TERM 后的等待时间（默认 1 秒）。未退出返回 `nil`，保留 PID，可继续
  `wait` 或 `hard_close`。
- `hard_close`：立即关闭所属 IO，不收集尾部输出；等待 `timeout:`，必要时发送 TERM 再等待同样时长，仍未退出则 KILL 并最多等待
  1 秒。默认 `timeout: 0.2`，必须有限。
- 两者返回已回收的 `Process::Status`，没有子进程或尚未回收时返回 `nil`；重复调用保留已获得的状态。借用 IO 不关闭。
- `close(graceful: false)`：可选先软关闭，`ensure` 中硬关闭，返回 `nil`。块生命周期使用它完成清理；软关闭发生日志异常时也会回收子进程。
- `wait(timeout: nil)`：等待并回收，返回 `Process::Status`；超时返回 `nil`。`process_status` 非阻塞查询，`exit_code`
  读取普通退出码，信号退出看 `process_status.termsig`。
- `closed?` 表示会话 IO 已关闭；`alive?` / `pid` 表示子进程状态。软关闭后可能同时 `closed? == true`、`alive? == true`。成功回收后
  PID 为 `nil`。

关闭只负责会话直接启动的子进程；垃圾回收提供非阻塞的强制清理兜底，不执行软关闭等待。优先使用块或 `ensure` 管理资源。

## 安全注意事项

- 将不可信命令和参数分别传给 `spawn`，例如 `Expect.spawn("ssh", host)`；单个命令字符串会使用 Ruby 的 shell 语义。
- 接收记录和诊断可能包含密码回显、令牌和其他敏感字节。调用方负责文件权限与留存，按需关闭 transcript、outputs 和 logger。
- `spawn` 在子进程中使用 `fork` 后的 Ruby 操作与 `exec`。高度多线程的宿主进程，尤其使用第三方 C 扩展时，可能受到 fork
  时其他线程持锁的影响；尽量在启动其他线程前创建会话，并在自己的运行环境中验证。
- 不可信正则可能耗费较长时间；使用带 `timeout:` 的 `Regexp` 实例，并为匹配缓冲设置合适的 `buffer_limit`。普通 `expect` 的
  IO 期限不打断单次正则或同步回调。

## 示例和验证

```sh
bundle install
bundle exec rake              # RuboCop + 完整测试
script/ci                     # 与 CI 相同：检查、测试、构建和隔离安装验证
ruby examples/dialogue.rb
ruby examples/kibitz/test_kibitz.rb
ruby examples/ssh_auto.rb      # 登录后执行命令，再交给人工输入
ruby examples/ssh_auto.rb --no-interact
ruby examples/ssh_interact.rb --auto
```

普通测试使用真实 PTY、管道和 socket，无需 SSH 服务或账户。Kibitz
的双终端示例与验证见 [examples/kibitz/](examples/kibitz/README.md)。

[GitHub Actions](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml) 在推送 `main`、推送 `v*` 标签、提交到
`main` 的 Pull Request 或手动触发时运行。流水线覆盖 Ubuntu 24.04 / macOS 15 与 Ruby 3.4、4.0 的 4 种组合；每个环境执行
`script/ci`，包括真实 PTY 测试和构建包的隔离安装验证。Ubuntu / Ruby 4.0 作业保留已验证的 Gem 构建产物 14 天，可从该次工作流的
Artifacts 下载。

运行前先执行 `bundle install`。Gem 库的开发锁文件 `Gemfile.lock` 保留在本地，各 Ruby 环境按 `Gemfile` 解析兼容依赖。生成文件写入已忽略的
`tmp/`，Gem 构建产物位于 `tmp/ci/`，发布候选包位于 `tmp/release/`。安装验证会清除外部 Bundler 环境，分别运行普通 RubyGems
加载和只声明 `expect-pty` 的 Bundler 应用，检查运行时依赖、终端模式、窗口大小及真实 PTY 对话。更新工作流中的 Action
时，应同步更新固定的提交 SHA 和版本注释。

运行时依赖只在 `expect-pty.gemspec` 声明，开发依赖放在 Gemfile 的 `development` / `test` 组；安装或使用本库不会引入
Minitest、Rake、RuboCop 及发布工具的依赖。

| 运行时模块         | Gem           | 用途                     |
|--------------------|---------------|--------------------------|
| `io/console`       | `io-console`  | 终端模式和窗口大小       |
| `IO#wait_readable` | Ruby 3.2 内置 | IO 可读等待，无独立 gem  |
| `logger`           | `logger`      | 标准诊断协议与级别       |
| `stringio`         | `stringio`    | Ruby `puts` 语义         |
| `pty`              | Ruby 自带扩展 | POSIX 伪终端，无独立 gem |

仅发布 RubyGems 使用 `ruby script/release.rb --rubygems-only`，直接复用本机已有的 Gem 登录状态；添加 `--dry-run`
可先完成本地检查、测试、构建和安装验证。需要同时创建 GitHub Release 时使用 `ruby script/release.rb`，也可以在 GitHub Actions
手动运行 Release 工作流。版本准备、Actions 凭据和失败重试见 [发布说明](docs/RELEASING.md)。

SSH 示例用 `SSH_USER`、`SSH_HOST`、`SSH_KNOWN_HOSTS` 配置，密码隐藏输入或从 `EXPECT_PASSWORD` 读取；非本地主机要求受信任的
known_hosts 文件。`ssh_auto.rb` 顶部 `COMMANDS` 可直接修改，日志写入 `tmp/ssh-auto/`，权限 0600。

多脚本验证入口为 `test/integration/ssh_scripts.rb`，人工/自动接管入口为 `examples/ssh_interact.rb`
，详细配置及日志检查见 [SSH 测试说明](test/integration/README.md)。

当前行为边界见 [接口说明](docs/COMPATIBILITY.md)，本次与历史验证分列在 [验证记录](docs/VERIFICATION.md)
。此次重构直接移除了旧入口，不提供兼容别名。
防火墙连接器已迁移到相邻的 `algosec` 项目；本库只保留 `Expect` 与 `expect-pty` 通用传输能力。

## 类型、文档与 0.7.0 接口变更

0.7.0 将 `Expect` 改为模块，公开真实 `Session`，移除全局配置、门面、终端命令包装和旧日志接口。
最低仍为 Ruby 3.4，保留不可变 `Result`。完整接口见 [API 文档](docs/API.md)，从 0.6.x 或更早版本升级前请阅读
[迁移说明](docs/MIGRATION.md)。类型签名随 Gem 发布在 `sig/expect.rbs`。

发布包仅包含运行源码、类型签名和使用文档。测试、基准、示例及维护脚本请从仓库取得；
运行 `bundle exec rake api` 验证文档覆盖与 RBS 声明，运行 `bundle exec yard doc --output-dir tmp/yard`
生成 HTML 文档。签名验证不代表全库已经通过静态类型检查。
