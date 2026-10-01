# 迁移说明

## 0.6.x → 0.7.0

0.7.0 主动移除门面和旧配置接口，不提供兼容别名。最低版本仍为 Ruby 3.4，`require "expect/pty"` 和不可变 Result 保持不变。

| 0.6.x                                                | 0.7.0                                            | 迁移含义                                                       |
|------------------------------------------------------|--------------------------------------------------|----------------------------------------------------------------|
| `Expect` 类与外层会话门面                            | `Expect` 模块、公开 `Expect::Session`            | 工厂、匹配回调、Result.session 和链式返回同一个 Session        |
| `Expect.new(...)`                                    | `Expect::Session.new(**settings)`                | 仅预建 PTY；命令及 env/chdir/raw 交给之后的 session.spawn      |
| `Expect.spawn` / `Expect.open` 返回 Expect           | 返回 Expect::Session                             | 类型判断与 RBS 引用改为 Session；有块仍返回块结果              |
| `Expect.configure`、`configuration`、`Configuration` | 显式会话关键字与属性                             | 应用共享默认值自行保存 Hash，调用时展开；不再继承类级配置      |
| `raw_pty: true` / `raw_pty=`                         | `spawn(raw: true)`                               | 每次启动的子终端操作参数                                       |
| `preserve_buffer = true`                             | `expect(consume: false)`                         | 每轮等待设置；默认仍消费成功匹配前缀                           |
| `reset_timeout_on_read = true`                       | `expect(reset_timeout_on_read: true)`            | 只作用于本轮相对期限，deadline 仍不可延长                      |
| `raw_terminal = false`                               | `interact(raw: false)`                           | 只作用于本次人工接管                                           |
| `graceful_close = true`                              | 工厂 `graceful: true` 或 `close(graceful: true)` | 块清理策略与直接关闭均显式指定                                 |
| `session.continue(...)`                              | `Expect.continue(...)`                           | 继续控制符只由模块提供                                         |
| `listeners`、`log_listeners`、`log_stdout`           | `outputs` writer 数组                            | 把 `$stdout` 显式加入；清空或替换数组控制转发                  |
| `debug_level`、`diagnostic_output`                   | `logger` / `logger=`                             | Ruby Logger 的 add/debug? 协议；级别、格式和输出由 logger 管理 |
| 诊断回调事件中的 `level`                             | Logger add 的 severity 参数                      | 事件 Hash 保留 event/pid/fd/message；不再生成 buffer 诊断      |
| `log_output`、`log_to`                               | `transcript` / `transcript=`                     | 只接收 writer；文件打开、权限、模式和关闭由调用方负责          |
| `write_log(*objects)`                                | `write_transcript(*objects)`                     | 补写记录，不发送字节，固定返回 nil                             |
| 路径日志、callable 日志                              | `File.open` 或实现 write 的目标                  | 库不拥有日志文件；write 必须返回已接受字节数                   |
| `session.stty(...)`                                  | `session.to_io` 的 io/console 方法               | 原生 raw/cooked/echo=/console_mode；不再启动辅助命令           |
| `session.winsize` / `winsize=`                       | `session.to_io.winsize` / `winsize=`             | 原生窗口尺寸操作                                               |

显式关键字只接受 timeout、write_timeout、buffer_limit、logger、transcript、outputs 六个会话设置。
未知关键字在 Ruby 方法入口抛出 ArgumentError，因此 `Expect.open(..., own: true, unknown: value)` 不接管 IO；
已知设置的非法值在初始化中失败，仍清理 own:true 的端点。logger、transcript、outputs 始终借用，关闭会话不关闭目标。

```ruby
require "expect/pty"
require "logger"

defaults = { timeout: 5, buffer_limit: 65_536 }.freeze
logger = Logger.new($stderr, level: Logger::INFO)
File.open("session.log", File::WRONLY | File::CREAT | File::APPEND, 0o600) do |transcript|
  Expect.spawn("/bin/sh", "-i", **defaults, logger: logger, transcript: transcript,
               outputs: [$stdout], raw: true) do |session|
    session.puts("printf 'ready\\n'")
    session.expect("ready", consume: false, reset_timeout_on_read: true)
    session.clear_buffer
    session.puts("exit")
  end
end
```

兼容 `add` / `debug?` 的 ActiveSupport logger 可直接注入，不需要为本库引入 ActiveSupport。
需要自定义诊断格式时设置 logger.formatter；需要自定义接收记录时实现 writer.write (String) 并返回已接受字节数。

内部 Session 协作协议通过 YARD `@api private` 标注，不因为 Ruby 可调用就成为发布契约。不要再访问门面实例变量或依赖旧配置类。
会话可以被应用扩展，但多个对象即使定义相同的 `==` / `eql?` / `hash`，仍是各自独立的读取来源与生命周期。

## 0.5.x → 0.6.0（历史）

从 0.5.x 直接升级到 0.7.0 时，先理解以下结果值变更，再应用上面的接口表。

- 最低运行环境改为 Ruby 3.4；支持 Ruby 3.4 和 4.0 的 Linux/macOS 组合。
- Result 从可变 Struct 改为不可变 Data；`result.match = value` 改为 `result.with(match: value)`。
- `result.to_a` 改为位置模式或优先使用键模式，如 `result => { number:, captures: }`。
- 结果文本和捕获值不可原地修改；调整编码用 `result.match.dup.force_encoding("UTF-8")`。
- `expect` 统一返回 Result，移除 expect_result；序号比较用 `.number`，成功用 `.matched?`，EOF/超时用 `.eof?` / `.timeout?`。
- 会话 before、after、match、match_number、captures、error 与 last_result 保留。
- 模式进入匹配器后冻结，运行中不能追加或替换本轮规则。
- Gem 仅携带源码、RBS 与使用文档；测试、示例、基准和发布脚本从仓库取得。
- 0.6.0 曾保留外层 Expect 门面和布尔配置，这两部分已由 0.7.0 的 Session 与操作关键字替代。
- 单字符串命令保留 Ruby 自动 shell 语义；多参数命令按 argv 传入。
