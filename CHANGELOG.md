# Changelog

## Unreleased

- 使用 Ruby 属性、谓词方法、关键字参数、原生 Regexp 和块回调；移除 `exp_*`、`get/set_accum`、读写合一方法、位置超时、字符串模式标志和数组回调，不提供兼容别名。
- 使用 `Expect.configure` 发布冻结的默认配置，每个会话独立持有设置；子类可独立覆盖，配置错误不发布部分修改。布尔值按 Ruby 真值规则处理，默认关闭 stdout 输出。
- 统一 `buffer_limit`、`preserve_buffer`、`log_listeners`、`raw_terminal`、`reset_timeout_on_read`、`debug_level` 等属性；移除全局正则和 EINTR 开关。
- `expect` 返回模式序号，`expect_result` 返回原生七字段 Struct；错误使用 `:timeout`、`:eof` 或原始 IO 异常。`from:` 选择会话，超时块接收全部仍活跃的会话，重复注册超时回调报错。
- `readable_sessions` 返回会话对象；日志使用 `log_output` / `log_output=` 和 `log_to`，注释日志使用 `write_log`；`on_sequence` 使用闭包，`0` 按 Ruby 真值继续转接。
- 保留并区分软关闭和硬关闭：`soft_close` 收集尾部输出、最多 TERM，未退出保留 PID；`hard_close` 必要时 KILL。显式关闭返回 `Process::Status`；`close(graceful:)` 确保清理并返回 `nil`，`graceful_close` 配置默认策略。
- `write`、`puts`、`<<` 采用 Ruby IO 的返回值和转换规则，移除会话 `print` 方法，`send` 保留反射语义；`send_slow(delay:)` 提供逐字符写入。
- 拆分配置、结果、资源状态和模式构建，整理匹配引擎；使用参数转发和 `ensure` 管理生命周期，初始化失败释放接管 IO，匹配被信号中断时保留期限。
- 为模块和主入口补充中文注释，说明方法用途，以及编码分片、匹配状态机、转接和资源清理思路。
- 同步库、示例、测试和迁移文档，移除 RuboCop 的兼容命名例外；CI 运行 `rake lint` 和完整测试，运行时仅依赖标准库。

- 精简 `ssh_auto.rb` 为直接使用本库的登录、命令执行和 interact 示例：修改顶部 `COMMANDS` 即可调整命令，移除测试 helper 与 JSON 报告，保留会话日志、命令超时和退出码检查；支持 `--no-interact` 自动退出。

- 新增 `examples/ssh_interact.rb` 人工与自动 SSH 交互测试，覆盖真实终端接管、Ctrl-C、Ctrl-]、自动化恢复与日志；修正人工模式无回显和测试输出的 CRLF 边界。
- 参考上游 Kibitz 新增本地双终端共享进程/无进程互传示例、可独立执行的测试脚本与日志报告，覆盖转义、EOF、异常退出、超时和终端恢复。

## 0.1.1

- 补齐 `test_handles` 等待期限和 `set_seq` 的 Ruby 正则序列，覆盖跨读取匹配和回调继续执行。
- 日志在实际读取时记录，避免切换 `expect` / `interconnect` 重复写入；日志目标的 IO 错误不再被误判为子进程 EOF。
- 新增真实 SSH 多脚本日志验证、5 个 shell fixtures 和自动回归测试；安装包包含测试代码、说明和 Rake 入口。

## 0.1.0

- 实现 Expect.pm 风格的 Ruby PTY 自动交互：模式、回调、超时、EOF、多会话和缓冲管理。
- 支持真实 IO 适配、日志、慢速发送、双向写入背压、人工交互转接及终端恢复。
- 提供受控进程关闭与回收、中文/二进制匹配、Ruby gem 打包和可重复执行的 SSH 验证示例。
