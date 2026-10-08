# expect-ruby

[![CI](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml)

[English](README.md) · [简体中文](README.zh-CN.md)

一个通过 POSIX 伪终端自动操作交互式程序的 Ruby 库。启动子进程、等待文本或正则匹配、发送输入，并用 Ruby 对象和代码块管理超时、回调与资源清理。

RubyGems 包名：**expect-pty**。要求 Ruby 3.4+，支持 Linux 和 macOS。

## 安装

在 Gemfile 中添加：

~~~ruby
gem "expect-pty", require: "expect/pty"
~~~

然后运行 `bundle install`，或直接运行 `gem install expect-pty`。

## 快速开始

~~~ruby
require "expect/pty"

program = "STDOUT.sync = true; print 'ready>'; STDIN.gets; puts 'done'"
Expect.spawn("ruby", "-e", program) do |session|
  prompt = session.expect("ready>", timeout: 5)
  raise "子进程未就绪" unless prompt.matched?

  session.puts("continue")
  result = session.expect("done", timeout: 5)
  puts result.match if result.matched?
end
~~~

代码块退出时会关闭会话并回收子进程，异常路径也会执行清理。不可信命令参数应分别传入；单个命令字符串遵循 Ruby shell 语义。

## 功能

- 按字节精确匹配字符串，或使用 Ruby Regexp；支持不可变结果、回调、超时和 EOF。
- 显式管理 PTY 会话或借用 IO 会话，支持作用域清理和进程状态查询。
- 多会话等待、IO 转发和人工终端接管。
- 可选的 Logger 诊断、接收记录和流式脱敏。

## 文档

- [API 参考](docs/API.md)
- [兼容性和行为边界](docs/COMPATIBILITY.md)
- [迁移指南](docs/MIGRATION.md)
- [性能说明](https://github.com/gatework/expect-ruby/blob/main/docs/PERFORMANCE.md)
- [示例](https://github.com/gatework/expect-ruby/tree/main/examples)

在源码仓库中运行 `script/ci` 执行测试和打包检查。测试使用本地 PTY、管道和 socket，不需要 SSH 凭据。

本项目使用 MIT 许可证。欢迎提交中文或英文贡献，详见[贡献指南](https://github.com/gatework/expect-ruby/blob/main/CONTRIBUTING.md)。
