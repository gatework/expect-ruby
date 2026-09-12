# 本地 Kibitz 示例与测试

参考 [Expect.pm 的 kibitz](https://github.com/jacoby/expect.pm/tree/master/examples/kibitz)，使用本项目的 `Expect.open` 块、`listeners=`、`on_sequence` 和 `Expect.interconnect` 连接两端输入与同一个交互进程。参考源码为上游提交 `2ea0e4ce20a896c95cb4c94e781f1b1f3145150d`。

需要 Ruby 3.2+ 和 macOS/Linux。示例和自动脚本只依赖标准库，不需要 SSH 服务或密码。

## 两个终端手工运行

在第一个终端运行：

```sh
ruby examples/kibitz/kibitz.rb -- /bin/sh -i
```

程序打印一条完整的 `--join /tmp/expect-kibitz-.../peer.sock` 命令。在本机、同一账户的第二个终端执行这条命令，两端即可操作同一个 shell。输入和输出在两端都可见，例如：

```sh
# 第一个终端设置 shell 变量
shared_value=42
# 第二个终端读取同一个变量
printf '%s\n' "$shared_value"
```

任一端输入 `exit` 结束共享 shell；Ctrl-C 发给共享进程的前台任务。任一端按 Ctrl-] 结束自己的转接并断开连接，另一端随 EOF 结束。终端配置在退出时恢复。可以通过 `-- program args...` 运行其他交互程序；不传程序时使用 `$SHELL`，缺省 `/bin/sh`。

## 无子进程互传和可选参数

```sh
# 输入只传给另一端，没有本地回显
ruby examples/kibitz/kibitz.rb --noproc

# 自定义本端转义键（第二端可在自己的加入命令中独立设置）
ruby examples/kibitz/kibitz.rb --escape '^X' -- /bin/sh -i

# 禁用本端转义，Ctrl-] 也作为普通数据转发
ruby examples/kibitz/kibitz.rb --noescape -- /bin/sh -i

# 等待加入最多 30 秒，加入后转接也最多 30 秒；日志文件必须尚不存在
ruby examples/kibitz/kibitz.rb --timeout 30 --log /tmp/my-kibitz-session.log -- /bin/sh -i
```

共享进程模式的日志记录该进程实际返回的字节，包括终端回显；无子进程模式记录对端返回的字节。日志使用 0600 权限。进程正常结束时，发起端返回该进程的退出码；转义或对端 EOF 返回 0，超时或连接失败返回非零。加入端只能观察连接结束，不取得共享进程的退出码。

这是同账户本地示例：连接使用 0700 临时目录内的 0600 Unix socket，接受一位加入者后移除 socket，退出时清理目录。原例的用户邀请、跨主机 rlogin、FIFO 以及转义菜单没有移植；双方终端初始尺寸由发起端决定，未实现运行期间的窗口尺寸同步。

## 自动运行同样的两个终端流程

```sh
ruby examples/kibitz/test_kibitz.rb
# 或
bundle exec rake test:kibitz
```

脚本真正启动两份 `kibitz.rb`，通过两个独立 PTY 模拟两位用户，并执行打印出的 Unix socket 加入流程。共享模式运行真实 `/bin/sh -i`，没有 mock 转发逻辑。

| 场景 | 检查 |
| --- | --- |
| 共享 shell | 输入回显、双方命令、共享变量、两端输出、中文、stderr、失败后继续执行 |
| Ctrl-C 与进程 EOF | 第二端中断第一端启动的前台任务，最终输出到达两端，进程退出 |
| `--noproc` | 双向字节互传，发送端无本地回显 |
| 自定义转义 | `STOP` 分两次发送，前缀不泄漏，转义和尾部不进入对端 |
| 加入端转义 | Ctrl-] 关闭加入端，发起端响应 EOF |
| `--noescape` | Ctrl-] 字节被完整转发 |
| 非零退出 | 共享 shell 返回 7，发起程序也返回 7 |
| 超时 | 转接到期返回失败，另一端结束 |
| 每个场景 | 就绪时已关闭本地回显，退出后两端终端配置恢复，socket 清理、日志权限正确 |

每轮结果写入 `tmp/kibitz/` 的独立目录，可用 `EXPECT_LOG_DIR` 指定其他目录。`report.json` 包含各场景检查项与整体 `passed`，各场景子目录保留 `session.log`。只有全部检查通过才返回 0。默认测试集还覆盖没有第二端加入时的超时清理：

```sh
bundle exec ruby -Itest test/kibitz_test.rb
bundle exec rake test
```
