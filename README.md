# expect-ruby

[![CI](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml)

用 Ruby 自动操作交互式程序：启动拥有控制终端的子进程，等待文本或正则，发送输入，处理超时、EOF 和回调，也能接管已有 IO、同时监听多个会话和转接人工交互。交互能力参考 [Expect.pm](https://github.com/jacoby/expect.pm)，接口采用 Ruby 的属性、关键字参数和代码块。

要求 **Ruby 3.2+、POSIX 系统（Linux/macOS）**。运行时仅使用 Ruby 标准库。推荐入口 **`require "expect/pty"`**；本项目提供独立的 `Expect` 类，不修改标准库的 `IO#expect`。

## 安装和运行

项目和仓库名为 `expect-ruby`，Gem 名为 `expect-pty`。本项目尚未发布到 RubyGems，可在应用的 Gemfile 中从 GitHub 安装，然后运行 `bundle install`：

```ruby
gem "expect-pty", git: "https://github.com/gatework/expect-ruby.git", branch: "main"
```

本地开发可改用 `gem "expect-pty", path: "/path/to/expect-ruby"`，也可在源码目录构建安装：

```sh
gem build expect-pty.gemspec
gem install ./expect-pty-0.1.1.gem
```

```ruby
require "expect/pty"

Expect.spawn("/bin/sh", "-i") do |shell|
  shell.puts("printf 'hello ruby\\n'")
  if shell.expect(/^hello ruby\r?$/, timeout: 3)
    puts shell.match
  else
    warn shell.error
  end
  shell.puts("exit")
  shell.soft_close(timeout: 2)
end
```

块返回其执行结果，退出时关闭会话并回收子进程，异常和 `break` 也执行清理。无块形式需用 `ensure` 显式调用 `close`。`Expect.new` 可以先创建 PTY、设置 `slave.echo` / `slave.winsize`，然后调用实例的 `spawn`。

多个命令参数原样传给 Ruby `exec`；单个命令字符串使用 Ruby 的 shell 语义。不可信参数应使用独立参数形式。支持 `env: { "NAME" => "value" }` 和 `chdir: "/path"`。同一会话只能启动一次，启动失败抛出 `Expect::SpawnError`。

## 配置与属性

```ruby
Expect.configure do |config|
  config.timeout = 10
  config.buffer_limit = 65_536
  config.graceful_close = true
end

Expect.configure(debug_level: 0) # 也可用关键字修改默认值
Expect.configuration.timeout   # 默认值快照，只读

Expect.spawn("/bin/sh", "-i", timeout: 3) do |session|
  session.timeout = 5
  session.log_stdout = true
  session.raw_pty?              # 布尔属性用问号方法查询
  session.puts("exit")
end
```

`configure` 校验后发布冻结的配置对象；块异常不会发布部分修改。每个会话独立持有配置，优先使用构造参数；修改默认值不会改变已有会话，修改一个会话也不会影响其他会话。子类继承父类默认配置，可独立覆盖。

| 属性 | 默认值 | 行为 |
| --- | --- | --- |
| `timeout` | `nil` | 等待匹配的默认超时，秒；`nil` 无限，`0` 非阻塞轮询 |
| `write_timeout` | `nil` | 写入遇到背压时的超时，秒 |
| `buffer_limit` | `nil` | 接收缓冲最多保留的字节数；正整数或 `nil`（无限） |
| `debug_level` | `0` | `1` 生命周期和匹配，`2` 加收发内容，`3` 加缓冲内容 |
| `raw_pty` | `false` | spawn 前将 slave 设为 raw，禁用回显和换行转换 |
| `preserve_buffer` | `false` | 匹配后保留完整缓冲 |
| `log_stdout` | `false` | 将接收内容输出到 `$stdout` |
| `log_listeners` | `true` | 将接收内容转发给 `listeners` |
| `raw_terminal` | `true` | 转接期间自动设置并恢复终端 raw 模式 |
| `reset_timeout_on_read` | `false` | 每次收到数据时重置匹配期限 |
| `graceful_close` | `false` | `close` 先尝试软关闭，再完成强制清理 |

布尔属性均提供 `name`、`name?` 和 `name=`，按 Ruby 真值规则转换：仅 `nil` / `false` 为假，`0` 为真。超时必须有限且非负，`nil` 表示无限；无效赋值不改变原值。`debug_level` 仅接受整数 `0..3`。

## 等待和匹配

```ruby
session.expect("literal text", /value=(\d+)/, timeout: 5)
session.timeout = 5
session.expect("ready")                # 使用会话超时
session.expect("ready", timeout: nil)  # 无限等待
session.expect("ready", timeout: 0)    # 匹配现有缓冲，并最多轮询读取一次
session.expect(timeout: 1)             # 仅收集输出，直到超时或 EOF
```

字符串始终按字面匹配，包括 `"-i"`、`"-re"`、`"timeout"` 和 `"eof"`；正则直接使用 Ruby `Regexp`。按声明顺序选择第一个能匹配的模式，不按它们在文本中的位置排序。返回模式的 **1 起始序号**，超时、EOF 或 IO 错误返回 `nil`。超时使用单调时钟。

```ruby
result = session.expect_result(/value=(\d+)/, timeout: 3)
result.matched?
result.timeout?
result.eof?
result.number
result.captures
result.session
result.error # nil、:timeout、:eof 或原始 IOError / SystemCallError 对象

number, error, match, before, after, session, captures = result.to_a
```

`Result` 使用原生 Ruby `Struct`，支持 `to_a`、`to_h`、模式解构；没有隐式 `to_ary`。会话提供 `last_result`，以及 `match`、`before`、`after`、`match_number`、`captures`、`error` 快捷读取方法。

成功匹配后删除匹配内容及其之前的内容，尾部留给下次匹配；超时保留缓冲，EOF 将未匹配内容放入 `before` 并清空缓冲。EOF 与子进程退出是不同事件，使用 `wait` / `process_status` 判断进程结果。底层 IO 错误保留原始异常，回调中的普通异常直接抛出。

接收缓冲、匹配和捕获值为 `ASCII-8BIT` 字节串，保留控制字符、NUL 和无效 UTF-8。UTF-8 正则支持跨读取拆开的字符；显示捕获内容时可 `.force_encoding("UTF-8")`。任意二进制流请用字面字符串或二进制正则 `/.../n`。固定 UTF-8 正则遇到无效数据抛出 `EncodingError`。缓冲上限按字节截断，应为文本设置足够的上限。

正则完全遵循 Ruby：`^` / `$` 是行锚点，`\A` / `\z` 是整个缓冲的锚点，`/m` 让点号匹配换行；不再提供全局正则模式开关。

## 回调、事件与多会话

```ruby
session.expect(timeout: 10) do
  on(/username:\s*/i) do |connection|
    connection.puts("demo")
    connection.continue
  end
  on(/password:\s*/i) do |connection|
    connection.puts(password)
    connection.continue(reset_timeout: false)
  end
  on("ready>")
  eof { |connection| warn "EOF: #{connection.before}" }
  timeout { |sessions| warn "timeout: #{sessions.length} session(s)" }
end
```

回调通过闭包访问局部变量。无参数声明块在模式构建器中执行；希望保留调用方 `self` 时使用 `do |patterns|`，调用 `patterns.on(...)`。所有模式注册完成后才读取 IO；注册异常或 `break` 不消费输入。块和位置模式不能混用。`expect_result` 支持同样的声明方式。

`continue` 继续等待并重新计时；`continue(reset_timeout: false)` 保留原期限，类和实例均可调用。无回调或返回其他值时结束本次匹配。超时回调只有返回重置计时的 `continue` 才再次等待。EOF 回调继续时移除该源并等待其余会话，全部 EOF 时立即返回。

`eof` / `timeout` 声明会占用模式序号，但事件返回的 `number` 为 `nil`。一个等待只能注册一个超时回调；它接收**所有仍在监听的会话**。不需要回调时，可将 `:eof` / `:timeout` 作为位置事件参数。

```ruby
Expect.expect(timeout: 5) do
  on(/ready/, from: [first, second]) { |connection| puts connection.inspect }
  on("done", from: third)
end

Expect.expect("ready", from: [first, second], timeout: 5)
```

`from:` 指定一个或多个会话；实例块默认当前会话，类方法需提供来源。相邻且来源列表相同的模式组成一组，按组、会话、模式顺序匹配。类方法省略超时使用 `Expect.configuration.timeout`。

`preserve_buffer = true` 时，继续回调应自行消费匹配，例如 `connection.buffer = connection.after`，避免重复匹配同一内容。无限超时与不消费缓冲的继续回调可以无限循环。被信号中断的匹配 select/read 会自动重试，保留原期限。

## 已有 IO、写入和终端

```ruby
Expect.open(socket) do |connection|
  connection.expect("prompt>", timeout: 5)
  connection.puts("command")
end

ready = Expect.readable_sessions(first, second, timeout: 5)
```

`Expect.open` 支持可 `select` 的 File、管道、Socket 和 PTY，`writer:` 可指定独立写端。默认借用 IO，关闭会话不关闭原始 IO；`own: true` 转移关闭责任，初始化失败也会释放接管的 IO。`StringIO` 可以用作日志和监听器，不能用作读取会话。

`readable_sessions` 返回可读的会话对象数组，不消费数据、不包含已关闭会话、同一会话只返回一次。默认 `timeout: 0`；`nil` 无限等待。同一会话应由一个读取者驱动，多会话共同监听使用 `Expect.expect`。

| API | 行为 |
| --- | --- |
| `write(*objects)` | 通过 `to_s` 转换并写入所有字节，返回字节数 |
| `puts(*objects)` | 原生 IO 风格的换行、数组递归和 `nil` 返回值 |
| `session << object` | 写入并返回会话，可链式追加 |
| `send_slow(*objects, delay:)` | 每个字符之前等待指定秒数，同时收集返回数据 |
| `buffer` / `buffer=` | 获取副本 / 复制字节并应用上限 |
| `clear_buffer` | 清空缓冲并返回旧内容 |
| `stty("raw -echo")` / `stty` | 修改终端模式 / 获取可恢复的模式字符串 |
| `winsize` / `winsize=` | 读取/修改 `[rows, cols]`，由内核通知前台进程 |
| `slave` / `tty_name` / `to_io` / `writer` / `fileno` / `tty?` | 底层 IO 和终端信息 |

大块写入遇到背压时同时读取输出，避免双向传输互相阻塞。超过 `write_timeout` 抛出 `Expect::WriteTimeout`，已写入字节不回滚。控制字符可直接发送，例如 `session.write("\x03")`，其信号作用取决于终端设置。`send`、`public_send`、`__send__` 保留 Ruby 反射语义。

## 日志与人工交互

```ruby
session.log_to("session.log")           # 文件追加
session.log_to("session.log", mode: "w") # 文件覆盖
session.log_to { |bytes| custom_logger.call(bytes) }
session.log_output = output_io          # 借用 IO 或 callable
session.write_log("annotation\n")
session.log_output = nil                # 关闭本库打开的文件，借用的 IO 保留
session.listeners = [output_io, another_session]
session.log_listeners = false
```

日志读取用 `log_output`，设置用 `log_output=`，打开路径或注册日志块用 `log_to`。不能同时提供日志目标与块。`listeners` 返回列表副本，`listeners = []` 清空；替换无效目标不会丢失原目标。

所有会话默认不输出到 stdout。日志仅记录实际读取的接收字节；写入不重复记录，终端回显可能作为接收内容返回。密码交互应关闭日志、调试，并确保被控程序不回显密码。

```ruby
session.interact(input: $stdin, escape: "\x1d", output: $stdout) # Ctrl-]

Expect.open($stdin) do |input|
  input.listeners = [session]
  session.listeners = [$stdout]
  input.on_sequence("\x1d") { false }
  Expect.interconnect(input, session, timeout: 60)
end
```

`on_sequence(sequence) { ... }` 注册字符串、原生正则或 `:eof`，通过闭包传递参数。无回调、返回 `nil` / `false` 停止，其他 Ruby 真值（包括 `0`）继续；字符串 `"EOF"` 按字面匹配。转接返回导致停止的会话，超时或所有 EOF 回调均继续时返回 `nil`。

字面转义可以跨读取完整过滤，尾部留给下次调用。正则转义使用受 `buffer_limit` 限制的历史记录，已实时转发的前缀无法撤回；零长度正则匹配抛出 `ArgumentError`。日志始终记录原始接收字节，包括被过滤的转义，在 `expect` / `interconnect` 之间切换也不会重复记录。

转接会自动设置并恢复终端 raw 模式；`raw_terminal = false` 将设置交给调用方。`interact` 还会恢复临时监听组、日志开关和转义设置，包括超时和异常路径。

## 软关闭、硬关闭与进程状态

```ruby
status = session.soft_close(timeout: 3, term_timeout: 1)
status ||= session.hard_close(timeout: 0.2)

session.close(graceful: true) # 先软关闭，必要时继续硬关闭
```

- `soft_close`：等待自然 EOF 并收集尾部输出，然后关闭所属 IO、等待进程退出；超时后最多发送 TERM，**不发送 KILL**。`timeout:` 是自然退出阶段的期限（默认 15 秒），`term_timeout:` 是发 TERM 后的等待时间（默认 1 秒）。未退出返回 `nil`，保留 PID，可继续 `wait` 或 `hard_close`。
- `hard_close`：立即关闭所属 IO，不收集尾部输出；等待 `timeout:`，必要时发送 TERM 再等待同样时长，仍未退出则 KILL 并最多等待 1 秒。默认 `timeout: 0.2`，必须有限。
- 两者返回已回收的 `Process::Status`，没有子进程或尚未回收时返回 `nil`；重复调用保留已获得的状态。借用 IO 不关闭。
- `close(graceful: graceful_close?)`：可选先软关闭，`ensure` 中硬关闭，返回 `nil`。块生命周期使用它完成清理；软关闭发生日志异常时也会回收子进程。
- `wait(timeout: nil)`：等待并回收，返回 `Process::Status`；超时返回 `nil`。`process_status` 非阻塞查询，`exit_code` 读取普通退出码，信号退出看 `process_status.termsig`。
- `closed?` 表示会话 IO 已关闭；`alive?` / `pid` 表示子进程状态。软关闭后可能同时 `closed? == true`、`alive? == true`。成功回收后 PID 为 `nil`。

关闭只负责会话直接启动的子进程；垃圾回收提供非阻塞的强制清理兜底，不执行软关闭等待。优先使用块或 `ensure` 管理资源。

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

普通测试使用真实 PTY、管道和 socket，无需 SSH 服务或账户。Kibitz 的双终端示例与验证见 [examples/kibitz/](examples/kibitz/README.md)。

[GitHub Actions](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml) 在推送 `main`、推送 `v*` 标签、提交到 `main` 的 Pull Request 或手动触发时运行。流水线覆盖 Ubuntu 24.04 / macOS 15 与 Ruby 3.2、3.3、3.4、4.0 的 8 种组合；每个环境执行 `script/ci`，包括真实 PTY 测试和构建包的隔离安装验证。Ubuntu / Ruby 4.0 作业保留已验证的 Gem 构建产物 14 天，可从该次工作流的 Artifacts 下载。

运行前先执行 `bundle install`。Gem 库的开发锁文件 `Gemfile.lock` 保留在本地，各 Ruby 环境按 `Gemfile` 解析兼容依赖。生成文件写入已忽略的 `pkg/ci/` 和 `tmp/`；流水线仅验证和保存构建产物，不自动发布 RubyGems 或创建 GitHub Release。更新工作流中的 Action 时，应同步更新固定的提交 SHA 和版本注释。

SSH 示例用 `SSH_USER`、`SSH_HOST`、`SSH_KNOWN_HOSTS` 配置，密码隐藏输入或从 `EXPECT_PASSWORD` 读取；非本地主机要求受信任的 known_hosts 文件。`ssh_auto.rb` 顶部 `COMMANDS` 可直接修改，日志写入 `tmp/ssh-auto/`，权限 0600。

多脚本验证入口为 `test/integration/ssh_scripts.rb`，人工/自动接管入口为 `examples/ssh_interact.rb`，详细配置及日志检查见 [SSH 测试说明](test/integration/README.md)。

当前接口迁移表见 [接口说明](docs/COMPATIBILITY.md)，本次与历史验证分列在 [验证记录](docs/VERIFICATION.md)。此次重构直接移除了旧入口，不提供兼容别名。
