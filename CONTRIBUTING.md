# 参与贡献

欢迎中文或英文 issue 和 PR。API、错误信息和示例中的可编辑命令保持直接清晰；库中的复杂生命周期和协议注释主要使用中文，英文说明同样欢迎。

## 本地检查

需要 Ruby 3.2+ 和 Linux/macOS。安装依赖后运行：

```sh
bundle install
bundle exec rake           # RuboCop 和默认测试
script/ci                  # 另含示例、Gem 构建及隔离安装验证
```

修改转接或匹配时，先运行对应的 `test/*_test.rb`，再运行 `bundle exec rake`。默认测试不需要 SSH；真实 SSH 集成测试的环境要求见 [测试说明](test/integration/README.md)。发布操作和历史验证分别见 [发布说明](docs/RELEASING.md) 与 [验证记录](docs/VERIFICATION.md)。

## 提交问题或改动

问题报告请附 Ruby 版本、操作系统、最小复现代码、预期与实际结果，以及必要的异常信息；日志中请删去凭据和会话敏感内容。修复行为缺陷时，先加入能在旧实现复现问题的回归测试。涉及缓冲、转义、背压或进程清理的改动，请对照 [内部状态与数据归属](docs/INTERNAL_CONTRACTS.md)，说明超时、EOF 和失败后的恢复行为。

PR 请说明行为变化、运行过的命令及结果。不要把本机生成的 `tmp/`、日志或凭据加入提交。
