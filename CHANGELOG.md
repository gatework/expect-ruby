# Changelog

## Unreleased

## 0.2.0 - 2026-09-13

- **不兼容变更**：接口统一采用 Ruby 属性、谓词、关键字参数、原生正则和块回调，移除 `exp_*`、`get/set_accum`、位置超时和数组回调等旧入口，不提供兼容别名，迁移方式见 `docs/COMPATIBILITY.md`。
- **配置与日志**：通过 `Expect.configure` 设置默认值，每个会话独立管理缓冲、日志、终端模式和超时策略，默认关闭 stdout 输出，日志入口统一为 `log_output`、`log_to` 和 `write_log`。
- **匹配与多会话**：`expect` 返回模式序号，`expect_result` 返回七字段 Struct，错误保留为 `:timeout`、`:eof` 或原始 IO 异常，`from:` 可选择会话，超时块接收全部活跃会话。
- **输入与转接**：`write`、`puts` 和 `<<` 遵循 Ruby IO 语义，`send` 保留反射用途，`send_slow(delay:)` 支持逐字符发送，`on_sequence` 使用闭包和 Ruby 真值控制转接。
- **进程清理**：`soft_close` 收集尾部输出并最多发送 TERM，`hard_close` 必要时发送 KILL，两者返回进程状态，块和 `close(graceful:)` 在异常路径也完成资源回收。
- **SSH 与双终端示例**：提供自动执行后切换人工交互的 SSH 示例和 Kibitz 双终端共享示例，支持转义退出、终端恢复和会话日志。
- **安装与运行**：通过 `gem install expect-pty` 安装，使用 `require "expect/pty"` 加载，支持 Linux/macOS 与 Ruby 3.2 及以上版本，运行时仅依赖标准库。

## 0.1.1

- 补齐 `test_handles` 等待期限和 `set_seq` 的 Ruby 正则序列，覆盖跨读取匹配和回调继续执行。
- 日志在实际读取时记录，避免切换 `expect` / `interconnect` 重复写入；日志目标的 IO 错误不再被误判为子进程 EOF。
- 新增真实 SSH 多脚本日志验证、5 个 shell fixtures 和自动回归测试；安装包包含测试代码、说明和 Rake 入口。

## 0.1.0

- 实现 Expect.pm 风格的 Ruby PTY 自动交互：模式、回调、超时、EOF、多会话和缓冲管理。
- 支持真实 IO 适配、日志、慢速发送、双向写入背压、人工交互转接及终端恢复。
- 提供受控进程关闭与回收、中文/二进制匹配、Ruby gem 打包和可重复执行的 SSH 验证示例。
