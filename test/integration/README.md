# SSH 多脚本和日志验证

在仓库根目录运行，要求 Ruby 3.2+、SSH 服务，以及能运行 POSIX `/bin/sh` 的目标账户：

```sh
SSH_HOST=127.0.0.1 SSH_USER=crate ruby test/integration/ssh_scripts.rb
# 也可以通过 Rake：
SSH_HOST=127.0.0.1 SSH_USER=crate bundle exec rake test:ssh
```

脚本隐藏读取密码；也支持由运行环境提供 `EXPECT_PASSWORD`。密码不会作为 SSH 命令行参数传递，日志在认证完成后才开启。默认自动测试不连接 SSH、不读取密码。

支持 `SSH_PORT`（默认 22）、`EXPECT_LOG_DIR`（日志根目录）、`SSH_KNOWN_HOSTS`。连接非本机主机时，必须提供已有的受信任 known_hosts，例如：

```sh
SSH_HOST=192.0.2.10 SSH_USER=operator SSH_PORT=22 \
  SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
  EXPECT_LOG_DIR=tmp/device-check ruby test/integration/ssh_scripts.rb
```

这是 POSIX shell 脚本测试；厂商专用 CLI（如交换机的 `show` 命令、分页提示符）需要对应设备的命令和预期输出，不能直接使用这些 shell fixtures。

## 同一个登录会话执行的脚本

| 脚本 | 验证内容 | 预期退出码 |
| --- | --- | --- |
| `01_identity.sh` | 当前用户、远端 PTY、完成标记 | 0 |
| `02_output.sh` | stdout、stderr、中文和输出顺序 | 0 |
| `03_delayed.sh` | 分三次延迟输出，确保日志完整 | 0 |
| `04_failure.sh` | 明确输出错误并退出 | 7（预期失败） |
| `05_recovery.sh` | 上个脚本失败后继续执行，计算结果为 42 | 0 |

fixtures 位于 `test/fixtures/ssh_scripts/`，都不修改目标文件或设备配置。文件内容通过 SSH 的交互 shell 传给独立 `/bin/sh -c` 执行，不需要上传文件。每个脚本都有随机开始/结束标记，结束标记携带真实 `$?`；脚本输出和退出码都必须符合预期才算通过。

测试关闭终端回显和 shell 行编辑，使用单引号传输完整脚本，保留中文 UTF-8 和引号，避免 C locale 的交互式 readline 把高位字节当快捷键执行。末尾仍等待 shell 提示符，确认可以继续执行下一项。

另外执行两条日志控制命令：关闭日志后输出 `UNLOGGED_OUTPUT`，再以默认追加模式开启日志并输出 `APPEND_OK`。最后发送延迟输出及退出命令，只调用 `soft_close`，确认 `SESSION_FINAL_TAIL` 确实在关闭过程中写入日志。

## 检查和输出文件

每次执行在 `tmp/ssh-logs/` 下创建独立目录，目录权限 0700，文件权限 0600：

- `session.log`：收到的原始数据，以及手工添加的 `[SEND] 脚本名 sha256=...` 和 `[EXIT] 脚本名 status=...`。
- `report.json`：主机、用户、远端 TTY、每项脚本输出和退出码、校验结果、SSH 退出码、日志字节数及 SHA-256。

只有认证后的输出进入日志。Expect 自动记录接收字节，发送的脚本名称和摘要由 `write_log` 明确写入，便于审核执行了哪个 fixture；fixture 文件中的原文可以用报告内的 SHA-256 核对。

共 11 项日志/流程检查：完整输出、执行顺序、即时 flush、stdout/stderr、UTF-8、非零退出后恢复、覆盖模式、暂停记录、追加模式、关闭前尾部输出、密码不出现在日志中。另校验日志条目没有重复，日志句柄在停止记录和关闭会话后正确关闭。

成功返回进程退出码 0。认证失败、超时、脚本输出错误、意外退出码或日志校验失败均返回非零，并在有报告目录时留下 `passed: false` 的报告。不用仅看到终端输出就判断成功；请查看最终 PASS 和 `report.json` 的 `passed`。

## 无需 SSH 的回归测试

```sh
bundle exec ruby -Itest test/script_logging_test.rb
bundle exec rake test
```

`test/script_logging_test.rb` 使用真实本地 PTY 执行相同 fixtures，另外验证回调日志、借用 File 日志、错误退出/错误输出的反例、引号和 shell 元字符、日志错误上抛，以及超时后继续收集日志。它和 SSH 脚本共享测试 helper，不依赖远端账户。

## SSH interact 人工和自动验证

```sh
ruby examples/ssh_interact.rb
ruby examples/ssh_interact.rb --auto
# 自动方式也可通过 Rake 运行
bundle exec rake test:ssh_interact
```

使用上述同一套 SSH 环境变量和隐藏密码输入。人工模式显示 `EXPECT_SCRIPT_PROMPT>`；输入命令有回显，Ctrl-C 传给远端前台任务。在命令结束、回到 shell 提示符后按 Ctrl-]，会关闭远端回显，执行 `MANUAL_AUTOMATION_RESUMED` 检查，再正常退出 SSH。也支持直接输入 `exit`：成功退出记为 `completion: remote_exit`，此路径不执行返回 expect 的检查。非零 SSH 退出仍判为失败。

`--auto` 创建真实本地 PTY，验证两次 `interact` 接管、当前用户和远端 TTY、stdout/stderr/中文、Ctrl-C、Ctrl-]、转义后的本地尾部不进入 SSH、恢复 `expect` 及终端与监听设置。4 项命令输出和 13 项交互/日志检查全部通过后才返回 0。

日志在认证之后开启；每次在 `tmp/ssh-interact/` 新建 0700 目录，保存 0600 的 `session.log` 和 `report.json`。报告包含检查项、命令输出、SSH 退出码及日志摘要。自动模式也校验日志无重复、退出尾部不丢失、密码不出现在日志中。

无需 SSH 的回归位于 `test/interact_test.rb`，覆盖可见输入、Ctrl-C、两次接管、返回自动命令、超时、两端 EOF、回调异常和输出 IO 故障时的终端恢复。`test/script_logging_test.rb` 另验证 CRLF 输出边界，包括空输出、末尾有/无换行和多个换行。

## `ssh_auto.rb` 环境检查

```sh
ruby examples/ssh_auto.rb
# 无人值守执行（密码可以由运行环境提供 EXPECT_PASSWORD）
ruby examples/ssh_auto.rb --no-interact
# 或执行 Rake 的自动退出入口
bundle exec rake test:ssh_auto
```

该示例自动登录 `SSH_HOST`（默认 `127.0.0.1`），用本库的 `write` / `expect` 顺序执行文件顶部的 `COMMANDS`，显示真实输出并检查退出码。默认命令为 `id`、`uname -srm`、`sw_vers`、`df -h /` 和 `uptime`，不修改系统设置；可直接修改数组来下发其他 macOS/POSIX shell 命令。它不依赖 `test/support`，`ScriptProbe.check` 只供测试脚本使用。

执行成功后默认进入 `interact`，输入有回显，Ctrl-C 发给远端前台任务；`exit` 或 Ctrl-] 结束连接。使用 `--no-interact` 则执行完退出。`EXPECT_LOG_DIR` 可指定日志目录，默认 `tmp/ssh-auto/`；每次创建独立 0600 日志，记录命令和远端输出，认证前关闭日志。此使用示例不生成 JSON 测试报告，详细日志断言仍由 `ssh_scripts.rb` 和 `ssh_interact.rb --auto` 验证。
