# expect-pty 开发指南

适用于本仓库。仓库名为 expect-ruby，gem 名为 expect-pty；不要混淆二者或引入会遮蔽 Ruby 标准库的 `lib/expect.rb`。

## 职责与契约

- `ResourceOwner` 维护 IO/PID 资源账本，`ChildProcess` 管理进程，`Session` 管理协议缓冲和公开状态；Matcher、Relay、Responder 只借用会话。
- 外部 IO、transcript 和日志目标按明确所有权关闭；初始化失败、取消、非局部退出也必须完成回收，清理错误不能随意覆盖主错误。
- 普通 expect 保留声明优先级；Responder 按字节位置应答，同位置的完成规则优先。不要用新的扫描优化改变优先级、EOF 或零宽规则行为。
- 相对超时与绝对 deadline 分开；绝对 deadline 不因读取或回调继续而延长。写超时保留已发送字节数，不自动重放。
- 文本和捕获容器先构造普通 String/Array 再校验，不继承输入复制钩子或冻结调用方；Result 的 PP 展示沿用安全摘要。
- 缓冲与匹配偏移使用字节；固定编码正则须处理不完整字符尾部，不能静默替换非法数据。公开缓冲/结果须遵守副本与冻结契约。
- LiteralScan 只能缓存规则身份与扫描坐标，不持有输入、会话或 IO；替换、消费、裁剪与转接必须使旧结论失效。
- Redactor 保留跨块秘密、重叠掩码、规则更新和 suppression 状态。移除规则不能释放旧隐藏字节；诊断摘要不能展开秘密或输入正文。

## 修改与验证

- 以 gemspec、锁文件和 CI 为运行时依据，当前测试矩阵为 Ruby 4.0.6/4.0；沿用中文注释、现有命名和 RuboCop 规则。
- 优先复用已有测试与抽象。缺陷先复现；性能改动必须比较相同输入、语义、源码来源、耗时和分配量，不使用共享机器的硬性能阈值。
- 保留全部既有改动；本地审查与修复不包含提交、推送、发布授权。
- 根目录运行 `bash script/ci`：lint、测试、API/RBS、示例、基准 smoke、构建、普通与 Bundler 隔离安装。macOS shell 选错 Ruby 时使用 `zsh -ic 'bash script/ci'`。
- 定向测试使用 `bundle exec ruby -Itest test/<name>_test.rb`。性能对比使用 `benchmark/*.rb --library /path/to/lib`，结果写到不同输出路径。
- 连接器联调应显式加载候选源码，并单独验证安装后的候选包；源码测试不能证明包内容正确，合成 PTY 不能证明远程 SSH/设备兼容性。
- 公共行为与性能改动更新 CHANGELOG；只有明确授权发布才执行远程交付。
