# 0.5.x → 0.6.0 迁移说明

0.6.0 包含以下不兼容调整；从 0.5.x 升级时需要同步修改调用代码。

- 最低运行环境调整为 Ruby 3.4；CI 验证 Ruby 3.4 和 4.0 的 Linux/macOS 组合。
- Result 由可变 Struct 改为不可变 Data。`result.match = ...` 改为 `result.with(match: ...)`；原结果保持不变。
- `result.to_a` 改为位置模式 `result => [number, error, match, before, after, connection, captures]`，或优先使用键模式 `result => { number:, captures: }`。
- 结果文本和捕获值不能原地修改。需要调整编码时使用 `result.match.dup.force_encoding("UTF-8")`，不要直接修改快照。
- 结果的 `session` 与回调参数仍为外层 Expect；内部运行状态移入 Session。外部代码不应访问实例变量或调用私有匹配、转接钩子。
- Gem 不再携带测试、基准、示例及发布脚本；这些开发材料从仓库取得。运行时依赖不包含 RBS、YARD 等开发工具。
- 类级和实例级 `expect` 统一返回 Result，移除 `expect_result`。旧的序号比较改用 `.number`；成功判断使用 `.matched?`，EOF/超时使用 `.eof?` / `.timeout?`。
- 保留会话上的 `before`、`after`、`match`、`match_number`、`captures`、`error`，它们读取最近结果；也可使用 `last_result`。
- 布尔配置只提供 `name?` 与 `name=`，构造关键字和配置 Hash 的键不变。
- 模式在进入匹配器时冻结，运行中不能追加或替换规则。每次等待重新声明所需模式。
- 单字符串命令保留 Ruby 自动 shell 语义；多参数命令逐项传入 argv。
