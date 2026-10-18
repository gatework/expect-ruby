# expect-pty 安全、匹配与生命周期改进设计

状态：用户“继续”批准实施；本文件不授权提交、推送或发布。

## 目标与证据

按 P1 安全与加载冲突、P2 性能和异常、参数一致性、结构重构的顺序实施。
现有工作区包含 Matcher、Relay、ResourceOwner 的未提交改动，必须保留，验证时分清这些基线与本次变更。
当前基线为 564 tests / 9499 assertions。已实际复现单字符串 shell 行为、入口冲突、SpawnError 无 cause、duration 宽松转换及约 12.5ms 关闭中位数。
仓库已有测试、RuboCop 和 Ruby 3.4/4.0 CI；README 已声明 Linux/macOS，不能把分发包不带开发文件误报成仓库缺失测试。

## 行为与兼容性方案

1. 默认按可执行文件及独立 argv 执行，不再隐式进入 shell。新增 `shell: true` 仅接受一个命令字符串，在 POSIX 上明确交给 `/bin/sh -c`。不接受 shell 模式与多个命令参数混用。保留现有命令校验、env/chdir 启动失败语义、raw 行为及所有权中断窗口，不额外夹带参数严格化。这个默认值变化必须记录为兼容性变更。
2. 主体迁入 `lib/expect/pty.rb`，移除 `lib/expect.rb`。同步子文件相对加载、测试、脚本及打包验证。新进程分别验证标准库 `require "expect"` 和本库 `require "expect/pty"` 的两种先后顺序。旧的本库 `require "expect"` 不再支持，迁移文档明确说明。
3. 保持 `Expect::SpawnError` 为公开启动失败类型。错误管道传递受控结构（异常类名称、消息和可用 errno），父进程重建 SystemCallError cause 并公开 errno。`SpawnError#errno` 为公开只读接口并同步 RBS；无 errno 时该接口返回 nil，cause 使用固定的内部启动异常类型，保留原异常类名称和消息，不任意重建宿主异常。禁止用 Marshal 或任意常量查找恢复子进程异常。不声称外层 SpawnError 可直接由 rescue Errno::ENOENT 捕获；调用方从 cause/errno 区分错误。
4. `search_window: nil` 保留完整正则语义。显式正整数表示尾部字节搜索窗口，只限制匹配扫描，不等于 buffer_limit，不截断 transcript；结果偏移换算回原缓冲。明确说明跨窗口、锚点及回看不等于完整流匹配；以独立窗口匹配为约定，不作任意正则的自动优化。该选项只属于本次等待，加入 Session#expect、Expect.expect 和 Responder#expect，经 Matcher 对每个来源分别应用；不增加 Session 默认配置，不改变 interact/interconnect。窗口同时限制字面量和正则的候选起点。二进制模式严格按尾部字节处理；UTF-8 正则若起点切入字符，则跳过该不完整前缀至下一完整字符（最多收缩窗口三个字节），不把字符窗口外部分带入匹配。窗口内其余无效编码仍按既有契约报错，窗口外字节不做正则编码检查；其他固定编码若被字节边界截断，沿用 EncodingError，不隐式转码。Result.before 和匹配消费仍包括命中前的全部原缓冲，after 保留完整尾部；consume:false 不消费。同步 API/RBS。不得偷偷改变字面量优先级和零宽匹配处理。
5. 子进程等待先尝试非阻塞回收，再使用约 1ms 起步、上限 10ms 的退避；每阶段使用同一单调期限，EINTR、零预算、TERM/KILL 与已回收 PID 行为保持。对比同一机器同一输入的多次中位数，不设 CI 性能阈值。
6. 相对秒数只接受 Numeric 或 nil，有限非负，所有无效输入统一 ArgumentError；拒绝 Complex、NaN、Infinity、字符串、布尔及符号，同步 RBS 与文档。绝对 deadline 同样仅接受非 Complex Numeric 或 nil，转换为有限 Float；允许负数作为已过期绝对时刻，不能复用非负 duration 的边界。所有非法类型和转换错误统一 ArgumentError。名称变化保留原方法兼容入口。
7. 先完成行为修复，再将已确认的进程监管职责提取为对象，围绕现有 ResourceOwner 保存唯一资源账本。Session 保留协议缓冲、公开 API 及与 Matcher/Relay 的协作。不能因行数或实例变量数量重复创建资源所有者。工厂调整须保留构造失败/异步中断的所有权窗口。内部方法逐项依据调用者分组，不能一律 private 后用 send 绕过可见性。
8. 日志按实际热路径采用惰性消息或入口守卫；脱敏掩码缓存只有在分配与耗时实测改善且不增加无界保留时采用。公开命名优先简洁与模块上下文；新增名称保留旧入口，不在修复中任意统一改名。中文注释、支持平台及作者元数据沿用既有项目政策。

## 验证与完成标准

- 每个缺陷先有真实入口的失败回归，再改代码跑绿；安全用例只执行合成无害命令。
- shell/argv、缺失程序、权限和 chdir 错误、加载顺序、duration 类型、正则窗口边界及全部原有等待语义均覆盖。
- 生命周期测试覆盖初始化每阶段失败、Thread.raise/Thread.kill、父子进程所有权、重复关闭、EINTR、信号及清理异常优先级。
- `bash script/ci` 包含 lint、全部测试、API/RBS、示例、基准 smoke、构建及 plain/Bundler 独立安装；不能只跑单元测试宣告完成。
- 已有未提交基线与候选在隔离目录复核，必要时用完整当前快照避免丢失既有工作。
- 性能报告注明输入、运行时、次数及分配；不把合成测试推断为真实设备性能。
- 不降低 Ruby 最低版本、改平台声明、删测试或加依赖来绕过验证；不自动发布版本。
