# 验证记录

## 当前源码：Ruby 原生接口与关闭策略（2026-09-12）

此次重构以 144 项测试 / 526 个断言为基线。原有交互场景全部迁移到新接口，新增 18 项回归，三个环境均通过 `bundle exec rake`（RuboCop 和完整测试）及 `ruby examples/dialogue.rb`：

| 环境 | 测试结果 | RuboCop |
| --- | --- | --- |
| macOS arm64，Ruby 4.0.6 | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |
| Linux aarch64，Ruby 3.2.11 | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |
| Linux aarch64，Ruby 4.0.6 | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |

新增检查覆盖配置发布的原子性、冻结与会话隔离、子类覆盖、无效赋值保留状态、Ruby 真值、字面模式标志、全部活跃会话的超时回调、重复超时注册、日志所有权。真实子进程验证软关闭收集尾部、响应 TERM、绝不发送 KILL、保留存活 PID、后续硬关闭和重复回收，以及自动清理、日志异常和无效关闭期限。模拟 EINTR 检查重复 select 中断不能延长期限、读取中断不丢输入。

最终会话输出接口统一为 `puts`、`write` 和 `send_slow(..., delay:)`，移除会话 `print` 和 `write_slow`。`lib/expect/` 的 9 个模块文件及主入口均补充中文注释，说明方法用途、匹配状态机、编码分片、转接缓冲、日志所有权和进程关闭；词法检查确认注释增补没有改变可执行代码。

原有 PTY、控制终端、信号、中文/二进制、背压、捕获组、匹配优先级、多会话、日志、interact 和 GC 测试继续全量运行。模块设置已收敛到配置对象；旧方法、位置超时、数组回调和 Perl 正则模式解析已移除，测试使用新 API。10 个文档 Ruby 示例块均通过语法检查。

macOS 的独立 `bundle exec rake test:kibitz` 也通过全部 6 个场景，报告位于 `tmp/kibitz/20260911T232907Z-20260912-9935-te8xfa/report.json`。本轮在 Linux Ruby 3.2 容器中重新运行 `test/compare_upstream.rb`，**11 组共同交互行为对照通过**；适配脚本使用新 Ruby API，显式转换错误标记及可读会话索引，原版 Perl fixture 未修改。

关闭策略另核对上游 `lib/Expect.pm` 的 `soft_close`、`hard_close` 和 `DESTROY`：软关闭最多 TERM，硬关闭可 KILL，销毁可先软后硬。Ruby 以 `graceful_close` / `close(graceful:)` 表达默认策略，以关键字配置等待期限；显式关闭返回 `Process::Status`，通用 `close` 返回 `nil`。

Linux 源码以只读方式挂载，使用 `BUNDLE_FROZEN=true` 和独立容器依赖目录；镜像摘要仍为下文记录的 `ruby:3.2` 与 `ruby:4.0`。Gemfile 和锁文件未改动，锁文件 SHA-256 为 `b1186a77057fba44bb79c440ffb6921042c16c1b88d213fabaa6548befb38d57`。macOS 复用了 `/tmp/expect-pty-gems` 的隔离依赖环境。

本轮没有重新连接真实 SSH 或运行远端 CI。`pkg/` 的 0.1.0 / 0.1.1 构建与记录仍代表历史版本；当前源码的接口见 README 和 COMPATIBILITY。以下各节保留其原验证时间、接口和范围，不作为当前接口的使用说明。

## 历史验证记录

验证日期：2026-09-11。上游参考版本 Expect.pm 1.38，提交 `2ea0e4ce20a896c95cb4c94e781f1b1f3145150d`。

## 自动测试

完整测试集包含 76 项测试，全部通过，无跳过：

| 环境 | 结果 |
| --- | --- |
| macOS arm64，Ruby 4.0.6 | 76 项通过 |
| Linux aarch64，Ruby 3.2.11 | 76 项通过 |
| Linux aarch64，Ruby 4.0.6 | 76 项通过 |

Linux 使用官方 Docker 镜像：

- `ruby:3.2`：`sha256:d3bcbd845d26ae1efafcc987f641aa9ac796267b9b857e0f196a2b05070c8330`
- `ruby:4.0`：`sha256:8dc3950712ad2078bdd275b890419ba2fd3aab5a0653b291a7325f0d8a24ca05`

测试范围包含真实 PTY 的控制终端、stdin/stdout/stderr、raw/noecho、终端尺寸、Ctrl-C 前台信号、退出码、TERM/KILL 回收、GC 兜底；模式优先级、捕获组、中文分片、二进制、缓冲上限；回调、事件、绝对/接收重置超时；多会话、日志、管道和 socket、大块双向 IO、写入背压；人工交互、跨读取转义序列、异常和超时后终端恢复；与 Ruby 标准库 IO#expect 共存。

macOS 改变终端设置后内核可能设置 PENDIN 临时状态位。终端恢复测试屏蔽这一状态位，比较其余完整配置；没有忽略真实的 echo、canonical、输入/输出、信号或控制字符设置变化。

复现：

```sh
bundle install
bundle exec rake test
```

本机全局 RubyGems/Bundler 安装存在版本混用，验证使用了临时 GEM_HOME 中的独立 Bundler 4.0.16、Rake 和 Minitest；未修改项目对 Bundler 的通常用法或用户的全局 gem。

## 上游差分验证

`test/compare_upstream.rb` 对同一输入分别运行原始 Perl 模块与本 Ruby 实现：字面模式、数组正则、跨行锚点、模式优先级、notransfer、缓冲上限、超时保留缓冲、连续回调、真实 PTY 对话。**9 组对照通过**。

对照在 Linux Ruby 3.2 容器内执行，Perl 依赖 IO::Pty / IO::Stty 仅安装到该临时容器。正则捕获及错误访问的 Perl 对象模型差异见兼容性说明；没有将它们伪装为一致行为。

```sh
# 此项是可选验证，需要 Perl 及 IO::Pty / IO::Stty。
ruby test/compare_upstream.rb /path/to/expect.pm
```

没有把这 9 项差分测试等同于运行完整 Perl 上游测试套件；功能覆盖同时依赖 Ruby 的 76 项测试和源码/API 对照。

## 真实 SSH

使用用户授权的 `crate@127.0.0.1` 完成真实 OpenSSH 密码认证，进入远端交互 shell 和 PTY。校验随机输出标记、`id -un` 返回 `crate`、`tty` 返回 `/dev/...`，随后 `exit`，SSH 退出码为 0。

测试随机标记由远端拼接，排除了仅匹配命令回显的误判。密码由隐藏输入读取或从进程环境取出，只保留在验证进程内，未写入源码、测试、文档和日志。临时 known_hosts 在退出后删除。

```sh
SSH_USER=crate SSH_HOST=127.0.0.1 ruby examples/ssh_login.rb
```

## 打包和范围

提供 `expect-pty.gemspec`、MIT LICENSE、中文 README、API 兼容性表、对话和 SSH 示例，以及 macOS/Linux 的 Ruby 3.2/3.3/3.4/4.0 CI 配置。CI 文件已进行 YAML 解析检查，远端 GitHub Actions 尚未运行。

初始构建物为 `expect-pty-0.1.0.gem`，补充后的交付版本为 `expect-pty-0.1.1.gem`，包含可运行的测试和 fixtures。安装验证在独立 GEM_HOME 中、从项目目录外运行 `require "expect/pty"` 和真实 PTY 对话，避免依赖源码目录的加载路径。

原生 Windows、其他 Unix、真实外部设备/外部 SSH 服务未实测。没有发布 gem、推送仓库或创建远端 Release；本次交付为本地源码和安装包。

## 补充验证：登录后多脚本与日志（2026-09-11）

新增 `test/script_logging_test.rb` 的 8 项真实 PTY 测试，及可单独运行的 `test/integration/ssh_scripts.rb`。自动测试总计从 76 项增至 84 项。新增测试共享 5 个 `.sh` fixture，覆盖多脚本日志文件、回调和借用 File、日志出错、异常退出码、输出不符、引号和中文传输，以及超时后的日志连续性。

最终全量回归：macOS Ruby 4.0.6 为 84 项 / 283 断言，Linux Ruby 3.2.11 为 84 项 / 283 断言，Linux Ruby 4.0.6 为 84 项 / 289 断言，均无失败、错误或跳过。Rake 的 `test:ssh` 入口已注册，Ruby 脚本和 5 个 shell fixture 的语法检查通过。

真实 SSH `crate@127.0.0.1` 已通过同一会话内的 7 项执行（5 个文件脚本，加日志关闭/恢复用例）及 11 项日志检查。第 4 个 fixture 故意返回 7，第 5 个仍执行成功；最终 SSH 退出码为 0。日志读取验证包含执行期间即时 flush、逐条顺序、无重复、覆盖/暂停/追加，以及 `soft_close` 收集最终延迟输出。

实际通过的日志和 JSON 报告保存在 `tmp/ssh-logs/20260911T124918Z-20260911-97383-lka948/`。目录被 Git 忽略，每次重跑生成新目录，失败时保留失败报告。

该成功会话日志共 1633 字节，SHA-256 为 `6b8abf4df93e1c40dec21a2b89c359bf4e2a9f9636791a83713150af5796672c`，与 JSON 报告的摘要一致；日志和报告均为 0600 权限。`pkg/` 中保留 0.1.0 作为初始构建记录，后续修正和测试脚本随 0.1.1 打包。

## 完整性复核与 0.1.1

复核上游实际代码后，补充 `test_handles(timeout, *sessions)` 等待语义，以及 `set_seq` 正则序列和跨读取回调，差分用例从 9 组扩展到 11 组。新增回归也覆盖从 `expect` 切换到 `interconnect` 再返回时的日志唯一性、转义后的原始日志，以及日志目标抛 IO 错误时保留输入并正确报告错误。

0.1.1 包含库源码、中文文档、完整测试与 5 个 `.sh` fixtures、Gemfile、gemspec 和 Rakefile。具体构建摘要和安装后的验证结果记录在构建物旁的 `pkg/VERIFICATION-0.1.1.txt`，避免文档与包自身摘要循环依赖。

SSH 首轮测试曾准确报告中文脚本退出 127；根据日志定位到测试 helper 的逐字节转义与远端 shell 行编辑相互影响。已改为完整脚本单引号传输，并禁用交互 shell 的 emacs/vi 编辑；重跑后中文、标准输出和错误输出逐字节匹配通过。

## 补充验证：interact 与本地 Kibitz（2026-09-11）

当前源码全量测试为 **109 项**，无失败、错误或跳过：macOS arm64 Ruby 4.0.6 为 380 断言，Linux aarch64 Ruby 3.2.11 为 380 断言，Linux aarch64 Ruby 4.0.6 为 386 断言。Linux 仍使用上文记录的两个镜像。这些新增内容记在 Unreleased，已有 0.1.1 构建记录保持为该包的历史验证结果。

新增 7 项 `test/interact_test.rb` 测试覆盖真实 PTY 接管、输入即时回显、远端 Ctrl-C、两次 Ctrl-] 返回、恢复自动化、超时/EOF/回调和输出异常后的终端恢复。另补 1 项 CRLF 输出分帧回归，检查空输出、无末尾换行和多个末尾换行。人工交互启用远端 echo，回到自动化时关闭 echo；自动脚本的无回显设置保留。TTY 身份探测的换行匹配不参与输出截取，不存在同一分帧问题。

实际 SSH `crate@127.0.0.1` 通过的三条路径，均记录 SSH 退出码 0，日志与报告权限 0600：

| 路径 | 结果 | 报告所在目录 |
| --- | --- | --- |
| 自动 PTY 交互 | 4 项命令、13 项交互/日志检查 | `tmp/ssh-interact/20260911T131311Z-20260911-367-hkxq5z/` |
| 人工输入后 Ctrl-] | 回车前可见 `printf` 输入，执行结果正确，返回后自动命令成功 | `tmp/ssh-interact/20260911T131343Z-20260911-423-7pgq5m/` |
| 人工直接 exit | 远端 EOF、终端恢复、正常退出，不执行自动化恢复命令 | `tmp/ssh-interact/20260911T132040Z-20260911-1777-qi6yry/` |

参考上游 `examples/kibitz` 源码的连接图，新增 `examples/kibitz/kibitz.rb` 和 `test_kibitz.rb`。本地示例通过 Unix socket 连接两份 CLI，各自运行于独立真实 PTY；共享模式启动真实 shell。`test/kibitz_test.rb` 新增 7 项测试，覆盖共享状态、输入回显、双向广播、中文/stderr、Ctrl-C、无子进程互传、自定义分片转义、禁用转义、非零退出、连接与转接超时、日志唯一性以及终端恢复和 socket 清理。

测试捕获并修正了就绪提示先于本地 raw/noecho 设置的启动时序问题；现在两端的就绪提示均在终端设置完成后发送。分片转义检查先确认普通前缀已到达对端，再发送转义的剩余部分，确保确实覆盖跨读取路径。

`bundle exec rake test:kibitz` 独立执行 6 个场景并全部通过，报告保存于 `tmp/kibitz/20260911T132223Z-20260911-2081-1poaup/report.json`，每个场景有独立 `session.log`。此验证参考并重现上游的本地交互行为，不代表移植或运行了上游的用户邀请、跨主机 rlogin 和转义菜单。

## Ruby API 与编码规范重构（2026-09-12）

本轮基线为 109 项测试 / 380 断言。新增 `test/ruby_api_test.rb` 的 35 项测试 / 146 断言，最终三种环境均通过完整的 `bundle exec rake` 和 `ruby examples/dialogue.rb`：

| 环境 | 完整测试 | RuboCop |
| --- | --- | --- |
| macOS arm64，Ruby 4.0.6 | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |
| Linux aarch64，Ruby 3.2.11 | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |
| Linux aarch64，Ruby 4.0.6 | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |

新增验证覆盖简洁 `expect(10) { on(...) ... }`、显式块参数保留调用方 `self`、闭包、可选块参数、注册时异常和 `break` 不消费输入、关键字与位置超时校验、EOF / 超时 / 多会话回调、继续等待及原期限；也覆盖借用和接管 IO 的块清理、初始化失败、缓冲和监听列表副本、日志块、原生 `puts` 的空参数/嵌套/递归数组、对象写入与链式追加。

`Result` 转换验证直接对照七个 Struct 字段，包括 `to_a`、`Array(result)`、`to_h`、位置/键模式解构及显式多重赋值；确认不再响应 `to_ary`。另验证 `session.send(:buffer)` 等 Ruby 反射调用和实际字节写入分离。原有 PTY、二进制、超时、进程回收、日志、interact、Kibitz 测试继续全量运行。

开发依赖固定在 Ruby 3.2 可运行的范围：RuboCop 1.89.0、parallel 1.28.0、Minitest 5.27.0、Rake 13.4.2，锁文件已补齐校验和。Linux 验证以只读方式挂载源码，使用 `BUNDLE_FROZEN=true` 安装同一锁文件；镜像仍为本文记录的 `ruby:3.2` 和 `ruby:4.0`。macOS 使用 `/tmp/expect-pty-gems` 中的独立 Bundler 4.0.16。

调用与迁移说明已同步至 README、兼容性表和示例；`send(data)` 需改为 `write(data)`，多重赋值需显式使用 `result.to_a`，`puts` 返回 `nil`。不冲突的 Expect.pm 入口继续作为兼容入口保留。本轮未重新连接真实 SSH、运行 Perl 上游差分或触发远端 CI；历史验证记录不作为这些路径本轮实测的证明。
