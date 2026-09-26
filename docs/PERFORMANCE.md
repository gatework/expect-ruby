# 性能基准

从源码目录安装开发依赖后运行，基准本身仅使用标准库：

```sh
bundle exec ruby benchmark/matching.rb
bundle exec ruby benchmark/relay.rb
bundle exec ruby benchmark/send_slow.rb
```

默认预热一次、采样五次。结果分别写入 `tmp/benchmark/matching.json`、`relay.json`、`send_slow.json`，该目录不提交。每个场景先核对非空输入的预期结果，再计时；每轮计时后再次核对最后一次执行的结果。输出包括 Ruby、平台、源码提交、工作区是否修改、库源码 SHA-256、输入规模、迭代次数、处理字节数、墙钟耗时、分配对象数和 GC 次数。

## 工作负载与边界

| 脚本 | 范围 |
| --- | --- |
| matching | 4 KiB、64 KiB、1 MiB；1、8、32 个正则；首个命中、末个命中、全未命中；UTF-8 前缀和可选捕获；1、8、32 个会话、多组重复来源和同时就绪的真实管道 |
| relay | 无转义、字面转义、16 个正则转义；正常目标与每次只接受 17 字节的目标共同接收相同数据 |
| send_slow | 真实本地 socket；无回显、持续回显；零延迟和每字符 1ms 延迟 |

`matching` 的扫描用内部 `find_match` 单独度量缓冲扫描，排除 PTY 启动和回调开销；就绪场景包含管道写入、选择和读取。`relay` 的前三项单独度量转义扫描，混合目标项运行完整转接循环。短写模拟目标吞吐受限，不等同于真实慢网络。`send_slow` 包含 socket、接收线程和完整回显校验的成本；无回显时计时止于接收方收齐数据。

处理字节数表示每轮提供给场景的输入字节数（混合目标为两份交付量），不是正则引擎实际访问内存的次数。分配量是整个 Ruby 进程的计数，socket 场景包含接收线程的分配。基准不提供 CPU 或网络隔离；耗时波动不能直接归因于代码变化。

## 同环境对照

对照目录必须包含已知提交的完整源码。两个版本使用同一套基准脚本、同一 Ruby 和依赖，在机器空闲时交替运行，比较原始样本的中位数与分配量：

```sh
bundle exec ruby benchmark/matching.rb --library /path/to/baseline/lib --samples 5 --output tmp/benchmark/before.json
bundle exec ruby benchmark/matching.rb --samples 5 --output tmp/benchmark/after.json
```

另外两份脚本支持相同参数。`--iterations N` 可增加单个样本工作量；比较双方必须使用相同参数。源码 SHA-256 用于区分同一提交上的未提交修改。修改工作负载后，应对两个版本重新取样。

没有 Git 的源码归档或安装目录仍可运行；提交和工作区状态记为 `null`，保留源码 SHA-256。

```sh
bundle exec ruby benchmark/matching.rb --smoke
bundle exec ruby benchmark/relay.rb --smoke
bundle exec ruby benchmark/send_slow.rb --smoke
```

`script/ci` 运行这些小规模正确性检查，不设置墙钟性能阈值。热点优化必须有实际收益证据；减少对象分配不代表所有输入都会变快，也不能替代完整测试和安装验证。
