# 验证记录

## 2026-10-08：长字面转义前缀扫描

本轮在上一轮未提交工作树上继续优化 `Interaction.queue_input` 的字面转义尾部扫描。冻结基线是本轮开始时保存的源码；候选只增加增量 KMP
前缀表和其会话内缓存，不新增依赖或公开 API。规则替换时移除已不再使用的表，避免临时 `interact` 转义规则在会话内累积。

回归对照在 2 KiB 重复前缀和末尾不匹配的数据上，冻结基线执行 2,048 次 `end_with?` 比较，候选执行 0 次；另用 200 个固定种子的
二进制键/缓冲样本对照最长后缀参考算法，覆盖表逐步扩展及规则替换后的缓存释放。
真实 `Expect.interconnect` 同脚本基准中，65,536 字节长规则未命中由 166.315 ms / 164,064 分配降至 14.387 ms / 219 分配。
完整负载、运行版本、源码 SHA-256 和边界见 [性能记录](PERFORMANCE.md#长字面转义前缀扫描2026-10-08)；样本保存在
`tmp/075-round2/relay-prefix-{baseline,candidate}.json`。

macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20 和 Linux aarch64 / Ruby 3.4.10 / Bundler 4.0.20 均通过 `bash script/ci`：
各为 **491 runs / 8,283 assertions**，零失败、错误或跳过；79 个文件 RuboCop、API/YARD/RBS、示例、五组基准 smoke、Gem 构建和
普通 RubyGems / 最小 Bundler 应用的隔离安装全部通过。Linux 使用冻结锁文件安装。已有测试替身方法重定义及本机 RDoc 版本告警仍会输出。
本轮未提交、发布或运行远端 CI。

## 2026-10-08：资源接管、日志交接与声明编译

基线为 `4313ee212b61e761e524689b3196938438154f7f`（0.7.4），本轮修改保留在 Unreleased，未提交或发布。
审查覆盖 Session/资源账本、Matcher/声明与结果、Relay/发送游标、Logging/Redactor，以及 API、测试、CI 和打包边界。
采用已有资源账本与 Ruby 的短范围中断屏蔽、冻结 Array/身份 Hash 编译声明，未增加运行依赖或公共配置。

- PTY.open、IO.pipe 创建与局部登记组成不可被异步中断拆开的接管区间；工厂先持有对象再初始化，未初始化对象也能安全退出。
  使用真实句柄及 TracePoint，在原生返回、初始化前后由另一线程执行 raise/kill，验证关闭责任与异常身份；用户初始化协议仍可中断。
- write_transcript 在全部对象转换结束后选定目标，整条补记及脱敏尾部归同一流；转换期间禁用目标不会向旧流补写。
- PatternList 冻结时编译纯文本组、完整来源及共享 EOF 组索引，保持默认无模式来源、身份顺序、显式 freeze 和列表复用。
  四个独立复审角度发现并修复了候选中“浅冻结被误判为已编译”的回归，最终架构与操作序列复审无新增发现。

新增 16 个测试方法，并将两项工厂清理测试改为真实工厂/子进程验证。相同的 resource_acquisition、pattern_compilation、
diagnostics 测试在独立基线和候选上分别为 **38 runs / 216 assertions / 9 failures** 与
**38 runs / 238 assertions / 0 failures**，均无错误或跳过。9 个红灯包含多种中断路径及性能扫描不变量，不等同于 9 类缺陷。

冻结候选的 107 个源文件与锁文件逐字节核对后执行完整 `bash script/ci`：

| 环境 | 结果 |
|------|------|
| macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20，独立源码目录 | 488 runs / 8,073 assertions，零失败、错误或跳过 |
| Linux aarch64 / Ruby 3.4.10 / Bundler 4.0.20，独立容器副本、冻结锁文件安装 | 488 runs / 8,073 assertions，零失败、错误或跳过 |

两套环境均通过 79 文件 RuboCop、API/YARD/RBS、示例对话、五组基准 smoke、Gem 构建，以及普通 RubyGems 和最小 Bundler
应用的隔离安装；两种安装均运行真实本地 PTY。两份包各含 21 个文件，逐字节匹配当前源码及 gemspec 清单。
macOS 测试包 SHA-256 为 `93f86d420320317894809bb3f58a8f00e2da29d43d69887ebeb2b8359bb3fe56`，
Linux 测试包为 `848115a5cffe235817bb34171ff84b1510bcb6fc75ec8cf9e5b207c34908d557`；它们是本地开发产物，不是已发布的 0.7.4 包。

512 来源 EOF 的 ABBA 对照耗时降低约 81%–82%，包含每次声明编译的公开入口保留收益；单来源新建 EOF 声明增加约
0.3–0.4 微秒/次。完整规模、分配量与非线性调度边界见 [性能记录](PERFORMANCE.md#eof-声明编译与公共入口2026-10-07)。
原始证据在 `tmp/075-review/`：`baseline-regressions.log`、`candidate-regressions.log`、`ci-macos40.log`、`ci-linux34.log`、
`candidate.json`、`package.json`、`package-linux34.json` 和 `final-*.json`。完整门禁后仅补充本验证记录，不改变运行代码或包内容。
macOS 首次独立目录检查误用系统 Ruby，显式指定 Homebrew Ruby 后重跑通过；成功日志仍有本机 RDoc 重复加载及测试替身警告。
本轮未运行远端 Actions、真实 SSH、设备或生产负载，也未声称完成四组合远端版本矩阵。

## 2026-10-06：0.7.4 发布候选

归档本轮三项修复至 0.7.4，并同步版本常量、安装示例和发布说明后，重新运行 `bash script/ci`，退出 0。
结果为 **472 runs / 8,002 assertions**，零失败、错误或跳过；77 个文件 RuboCop、API/YARD/RBS、示例、五组基准 smoke
以及普通 RubyGems / 最小 Bundler 应用的隔离安装全部通过，两种安装均验证真实本地 PTY。
运行环境仍为 macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20；原始日志为 `tmp/release/0.7.4/ci-local.log`。
此前性能与回归对照使用下节记载的 0.7.3 候选库，发布准备仅调整版本及文档。

## 2026-10-06：匹配进展与缓冲热点

基线为 `ec1f43101651bd7b711cf263159a579f0f6a9f11`（0.7.3），修复保留在工作区的 Unreleased 范围，未提交或发布。
Matcher 使用实际接收字节计数识别嵌套读取的进展；Relay 替换已排队后的尾部而非逐块删除前缀；Redactor 仅扫描
可能跨越新增字节的起点，并在规则更新后重扫保留窗口。没有新增运行依赖或公开 API。

新增 `matching_progress_test` 的同一份测试在冻结基线与候选上分别得到：
**5 runs / 18 assertions / 3 failures** → **5 runs / 27 assertions / 0 failures**。
覆盖消费与非消费匹配、其他模式及 timeout 回调内读入相同消息，以及同值赋回和空轮询仍受防空转保护。
另补充大缓冲经非消费 expect 交给 Relay 的完整交付与 Result 快照隔离，以及脱敏规则更新后的重新扫描与旧掩码保留。

macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20 上运行 `bash script/ci`，退出 0：

- **472 runs / 8,002 assertions**，零失败、错误或跳过；77 个文件 RuboCop 无违规。
- 公开 API/YARD/RBS 覆盖、RBS validate、示例对话通过。
- 五组 benchmark smoke 通过，含新增的已缓冲转接和长短秘密混合分片。
- Gem 构建、普通 RubyGems 与最小 Bundler 应用的隔离安装通过，均执行真实本地 PTY 验证。

额外对照 1000 条固定种子的过滤流，每条交错执行 40 次 append、suppress、规则更新及不同 partial 策略的 finish，
逐次输出与冻结基线完全一致。构建包的全部 21 个文件与当前源码逐字节一致，文件清单与 gemspec 一致。

性能比较使用独立基线库、相同驱动及串行采样，详细规模与原始数据见
[性能记录](PERFORMANCE.md#已缓冲转接与混合秘密分片2026-10-06)。日志保存在 `tmp/074-review/ci.log`、
`matcher-before.log` 和 `matcher-after.log`。完整门禁后仅补充不随 Gem 分发的内部合同、性能及本验证记录。
日志仍有测试替身重定义及本机 RDoc 重复加载警告；本轮未运行 Ruby 3.4、Linux、远端 Actions、真实 SSH 或设备验证。

## 2026-10-06：输入连续性与慢速发送恢复

在 `1003584ba9a679d172b66cae6378d04e6f61dc21` 及上一轮未提交修复上继续，先冻结本轮起点，再检查匹配、转接、发送、
日志与生命周期的交接路径。版本保持 0.7.2，未提交、推送或发布。并行评审代理因额度不足中止，主流程串行补完对应范围；
代理中止不计为独立评审通过。没有扩大到新的公开接口、配置或依赖。

| 边界 | 旧代码证据与修复 |
|------|------------------|
| 正则转义历史连续性 | 已转发 ST，expect 消费 NOISE 后再输入 OPtail，旧版错误识别 /STOP/。匹配实际消费、显式替换/清空和窗口裁剪现在清除历史；内部 take_buffer 只交接所有权，连续转接和非消费匹配继续保留历史 |
| send_slow 失败进度 | 真实管道发送 a中b，已交付 a 与中的首字节，旧版仅报告 1 字节，修复后报告累计 2 字节。对象转换和回复记录的嵌套超时不计入外层进度；原异常保留在 cause，首字符 write 的无需调整错误原样传播 |

本轮新增 10 个测试方法，覆盖零宽匹配、非法 setter、未实际裁剪的上限、嵌套匹配，以及多字节字符中途失败后的按字节续发。
先观察回归失败再修复；最终同一组 relay_history / write_contract 测试对照为：
起点运行库 **17 runs / 99 assertions / 7 failures / 0 errors / 0 skips**；
候选运行库 **17 runs / 130 assertions / 0 failures / 0 errors / 0 skips**。
这是两类缺陷的多条回归，不把失败方法数当作独立缺陷数。

冻结候选的 103 个源码文件及依赖锁文件逐字节核对与工作区一致，在独立目录、显式 Homebrew Ruby 路径下执行
`bash script/ci`，macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20，退出 0：

- Minitest：**465 runs / 7,962 assertions**，零失败、错误或跳过。
- RuboCop：76 文件无违规；公开 API/YARD/RBS 覆盖、RBS validate、示例对话通过。
- matching、relay、send_slow、scaling、redactor 五组 benchmark smoke 全部通过。
- Gem 构建、普通 RubyGems 与最小 Bundler 应用的两种隔离安装通过，均验证真实本地 PTY。
- 构建包的全部 21 个文件与工作区逐字节一致；主工作区 `actionlint` 和 `git diff --check` 通过。

性能另以同一驱动串行交替复测，16 MiB 持续读取仍约 12 ms，全部输入及回显校验通过；详见
[性能复核](PERFORMANCE.md#输入连续性与慢速发送修复复核2026-10-06)。本轮着重恢复正确性，不宣称新增吞吐收益。
原始证据在本地忽略目录 `tmp/contracts-review/`，包括起点/候选清单、`baseline-regressions.log`、`ci-macos40.log` 和 `package.json`。
测试包 SHA-256 为 `b4557b38d195fbdb2432ed906c8dca940341f9090d86fd888502a290670841db`，不是新发布版本。
完整门禁后仅补充不随 Gem 分发的内部合同、性能和验证文档；运行代码、测试与包内容未再变化。
成功日志仍含测试替身重定义和本机 RDoc 重复加载警告。未执行 Ruby 3.4、Linux、远端 GitHub Actions、真实 SSH 或设备验证。

## 2026-10-06：流式组件的性能与恢复边界

基线为 `1003584ba9a679d172b66cae6378d04e6f61dc21`，本轮修改留在工作区，版本保持 0.7.2，未提交或发布。
按 ruby-rails 与 Waza 的深度审查流程复核 Matcher、Session、Logging/Redactor、Interaction/Relay/RelayWriter 的调用链与失败恢复。
并行评审代理因额度或运行权限错误未返回结论；匹配、日志与转接范围由主流程串行补完，不把失败的代理任务记为独立评审通过。

| 边界 | 修复及可复现证据 |
|------|------------------|
| 持续增长缓冲 | 单轮扫描只读借用，保留公开副本和回调变化检测；真实管道 16 MiB 从约 835 ms 降至 12 ms，完整输入及 EOF 校验通过 |
| 共享 IO | 两个会话包装同一 IO、16 KiB 窗口及 32 KiB 输入，先匹配 READY 再继续读取；旧版多读导致窗口丢弃匹配内容 |
| 诊断级别切换 | DEBUG → INFO → DEBUG 仍识别跨块秘密，关闭期间字节不能在恢复级别或 finish 时补记；追加所有分割点、规则更新及二进制重叠回归 |
| 转接诊断与短写恢复 | 实际接受字节后才推进目标发送诊断，异常不回退游标；嵌套超时报告外层已写入 2 字节，cause 保留内层的 97 字节 |
| 转接总期限 | 直接、延迟转义及 EOF 继续回调和字面前缀扫描后检查正数预算；到期保留尾部，零轮询及明确停止优先级保持 |
| 接收回调重入 | 日志、transcript、同步 outputs 交付中递归读取同会话会抛出 ReentrancyError，避免后块越过前块；已有缓冲匹配及独立来源仍可用 |

先增加回归观察失败，再修改实现。最终 `stream_contract_test.rb` 单独装载基线运行库复核：
14 runs / 35 assertions / 11 failures / 0 errors / 0 skips；同一组在候选中为 14 runs / 93 assertions、全部通过。
脱敏随机字节区间差分和既有短写、EINTR、重入、EOF、对象身份测试继续保留。
性能收益和普通脱敏约 2%–6% 的部分负载代价见 [性能对照](PERFORMANCE.md#持续读取与诊断修复对照2026-10-06)。

从基线源码归档应用本轮差异和新增测试，逐字节核对全部 102 个源码文件与主工作区一致，并复制当前依赖锁文件。
在 macOS arm64 / Ruby 4.0.6 / Bundler 4.0.20 的独立副本执行 `bash script/ci`，退出 0：

- Minitest：**455 runs / 7,887 assertions**，零失败、错误、跳过；相比基线增加 17 个测试方法。
- RuboCop：75 文件无违规；公开 API/YARD/RBS 覆盖、RBS validate 和示例对话通过。
- matching、relay、send_slow、scaling、redactor 五组 benchmark smoke 通过，含新增真实管道持续读取。
- Gem 构建及普通 RubyGems、最小 Bundler 应用两种隔离安装通过，验证真实本地 PTY、依赖与包内容。
- 主工作区额外执行 `actionlint` 和 `git diff --check`，均退出 0。

独立目录首次误用系统 Ruby 2.6，在依赖加载阶段退出；显式固定 Homebrew Ruby 路径后完成上述完整检查。
旧代码回归补验的首次普通 Ruby 调用选中不含 minitest/mock 的版本，改用同一 Bundle 后才取得上述断言失败证据。
这两次环境失败均不计为产品回归或验证通过。成功 CI 日志仍含测试替身重定义和本机 RDoc 重复加载警告。

日志和冻结清单位于本地忽略目录 `tmp/stream-review/`：`ci-macos40.log`、`old-code-regressions.log` 和 `manifest.json`。
本地测试包 SHA-256 为 `a403111e32c04f3b815167f2244c4172856af80b213b6d09064e1309b5859037`；它不是新发布版本。
完整门禁后只追加本节维护记录，不改变运行代码、测试或包内容。
未运行 Ruby 3.4、Linux、远端 GitHub Actions、真实 SSH 或设备连接；本地通过不代替这些验证。

## 2026-10-01：原目标完成审计

以已提交的 `34a1e2b` 再次核对逻辑、性能、可靠性、最佳实践与本地交付要求。将四组 CI 的源码清单逐文件与当前内容比较，
运行源码、全部测试、RBS、构建与 CI 工具均一致；仅验收后补记的验证文档及本次性能文档不同。因此沿用下节四环境结果，
不把这次核对描述为重新执行全部矩阵。

独立复核在当前源码上分别重跑生命周期/转接/终端等 16 组（180 tests / 1,348 assertions）与日志/脱敏/SSH 参数等相关组
（71 tests / 4,974 assertions），均无失败、错误或跳过；两组有重叠，不合并为新的全库计数。
ActiveSupport Logger 实际注入和本机 OpenSSH 离线配置解析再次通过，没有新的可复现核心缺口。

性能完成证明使用当前源码与原优化前基线，在同一运行时、同一驱动中交替采样，覆盖 512 来源 EOF、256 来源密集/稀疏转接及
长尾脱敏与密集候选对照；全部输出和发送状态校验通过。当前收益与具体边界见 [性能复核](PERFORMANCE.md#070-完成复核2026-10-01)。
修正性能文档中仍把现行 Relay 基准描述为仅扫描的旧句子。本次补充只修改两份不随 Gem 分发的维护文档，版本保持 0.7.0，
已验收 Gem 的 SHA-256 仍为 `eb5a60a28147d9efb892508608f50f5e886b5839c4ac991396473ee56a5124a9`。

本次审计与文档补充继续仅提交本地 Git，不推送或发布。实际 SSH、网络设备、远端 CI 和生产负载仍未执行。

## 2026-10-01：0.7.0 标准库与会话接口重构

以 `4ab73da` 为基线，按明确允许不兼容变更的要求审查全库逻辑、资源生命周期、命名、重复实现、测试与打包。
删除外层会话门面、全局 Configuration、日志路径所有权和 stty 辅助进程；公开真实 Session，使用显式操作参数、标准
Logger、File.open 与 io-console。
匹配、原始字节、流式秘密过滤、背压游标和有限进程回收仍由各自的业务合同约束；本轮不把代码减少直接宣称为吞吐提升。

复审中用回归先观察到失败，再修复以下边界：

- 公开 Session 定义值相等时，Matcher 的暂停状态、嵌套转接缓冲以及 Relay 的来源、活跃集合和背压目标仍须按对象身份归属。
- `Expect.open(own: true)` 在 Session 分配前被中断时也关闭所属 IO；借用 IO 保持打开，原异常身份保留。
- 块已有主异常时，关闭冲刷中的 transcript writer 或 Logger formatter StandardError 不覆盖它；无主异常仍抛清理错误，新发生的
  Interrupt/SystemExit 不被吞掉。
- SSH 示例的 known_hosts 路径同时遵守 argv 和 ssh_config 两层解析，含空格、引号和反斜杠时仍是一个原路径。

移除的测试对应已删除的门面、配置和辅助进程接口；PID、GC、EINTR、原始字节、错误归属、终端恢复和短写恢复继续验收。
API 门禁按具体方法的 YARD 标注识别内部协议，保留缺文档/缺签名的负向检查；测试替身恢复原生 Class 方法查找链，避免随机执行顺序污染
API 检查。

### 独立环境验收

从基线创建 detached worktree，应用完整差异和 7 个新增文件，并逐文件核对与主工作区一致。
最低 Ruby 与 Linux 使用同一份 101 文件源码归档；Linux 容器禁用网络，从本地 Gem 缓存安装依赖。
四组最终 `bash script/ci` 均退出 0：

| 环境                                    | Minitest                                        | 其余门禁                                                                         |
|-----------------------------------------|-------------------------------------------------|----------------------------------------------------------------------------------|
| macOS arm64 / Ruby 3.4.11               | 428 runs / 7,170 assertions；零失败、错误、跳过 | 74 文件 RuboCop、API/RBS、示例对话、五组 benchmark smoke、Gem 构建与两种隔离安装 |
| macOS arm64 / Ruby 4.0.7                | 同上                                            | 同上                                                                             |
| Linux aarch64 / Ruby 3.4.11（bookworm） | 同上                                            | 同上                                                                             |
| Linux aarch64 / Ruby 4.0.7（bookworm）  | 同上                                            | 同上                                                                             |

两种安装分别为普通 RubyGems 和仅声明 expect-pty 的 Bundler 应用，验证实际加载路径、包清单、运行依赖、终端模式/尺寸、真实本地
PTY 对话、过滤与缓冲合同。
首次 Ruby 4.0 离线安装因目录未携带新运行依赖 Logger 而失败；代码测试已通过。修正 script/ci 仅复制本次解析的非默认运行依赖缓存后，四组完整重跑均通过。
没有通过宿主 GEM_PATH 或开发依赖绕过安装边界。

额外实际验证 Ruby 4.0.7 / Logger 1.7.0 / ActiveSupport 8.1.4 的 Logger、TaggedLogging 与 BroadcastLogger 注入，
包括不可变事件、原始匹配、transcript 脱敏和借用目标不关闭。未将 ActiveSupport 加入 Gem 依赖。
macOS OpenSSH 10.2p1 与 Linux OpenSSH 9.2p1 的 `ssh -G` 对五类特殊字符路径均返回原路径；这些检查不建立连接。

对已构建的 `expect-pty-0.7.0.gem` 执行 `script/release.rb --dry-run --rubygems-only --artifact ...`
，核对版本、说明、包内容和权限；不查询或上传远端。
完整 CI 与 dry-run 日志在本地忽略目录 `tmp/conventions-review/`，源码清单为其中的 `manifest.json`。

本次仅提交本地 Git，不推送、不打标签、不发布 RubyGems。未运行远端 GitHub Actions、真实 SSH 登录、网络设备或生产持续负载；本地
PTY 与离线配置解析不代替这些证据。

## 2026-09-30：0.6.1 本地提交准备

将两轮审查的兼容性修复和性能优化归入 0.6.1，同步版本常量、README 安装示例和发布文档；0.6.0 迁移说明及历史证据保持原记录。

以 `961c4d8` 的独立工作树应用完整待提交差异，确认与主工作区一致后，在 macOS arm64、Ruby 4.0.7、Bundler 4.0.20 执行
`bash script/ci`：

- 421 tests / 7,235 assertions，零失败、错误及跳过；71 个 Ruby 文件 lint 通过。
- API 文档/RBS 覆盖、RBS validate、示例对话和五组 benchmark smoke 通过。
- 构建 `expect-pty-0.6.1.gem`，普通 RubyGems 与最小 Bundler 应用的隔离安装、真实本地 PTY 和核心契约检查通过。
- 对同一构建包执行 `script/release.rb --dry-run --rubygems-only --artifact ...`，版本、发布说明、包内容和权限校验通过；该路径不调用远端查询或上传。

日志位于 `tmp/local-release-0.6.1/ci-macos40.log` 与 `dry-run.log`。本次版本整理未改变运行逻辑，先前 Ruby 3.4/Linux
矩阵见下文，本次未重复执行。
本次仅提交本地 Git，不推送 GitHub、不创建标签、不发布 RubyGems。

## 2026-09-30：逻辑与性能复审

在 `961c4d8` 及上一轮未提交修复上继续，使用 Waza 深度审查和 ruby-rails 契约检查。
分别复审匹配与结果归属、转接与背压、日志与脱敏，并交叉检查发送进度、进程/句柄所有权、终端和配置边界。
保留当前 Matcher、Relay、Session 与不可变 Result 的职责分工，无新增公共接口或运行依赖。

### 可靠性修复

| 问题                                           | 修复前证据                                                                                     | 修复与回归                                                                  |
|------------------------------------------------|------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------|
| EOF 后继续等待，后续 select 错误覆盖已结束来源 | 故障注入后返回的来源错误地指向已结束会话，其 EOF 与尾部结果被覆盖                              | 只更新活跃来源，保留原始异常及已结束来源的 Result 对象                      |
| 发送前嵌套写入的进度被算入当前命令             | 诊断回调或 `to_s` 向第二条真实管道写入 2 字节后超时，当前命令未发送却报告 `bytes_written == 2` | 当前 write 报告 0，cause 保留嵌套进度 2；确认命令管道为空，随后完整重试成功 |

上述缺陷先观察到失败再修复；另补 EOF 重复来源去重/顺序、批量就绪反序下的身份/声明顺序保护。
本轮共增加 4 个测试方法，原有随机脱敏差分断言全部保留。日志与安全复审未发现其他有充分证据的新缺陷，
不据此声称不存在未知问题。

性能修复限定在已处理 EOF 集合、Relay 就绪成员检索、脱敏流尾部的无效前缀扫描。
增加可复现负载并测量基线/候选；撤换会使密集脱敏候选变慢的首版实现。
最终数据、分配代价、控制负载及复杂度边界见 [PERFORMANCE](PERFORMANCE.md)。

### 完整本地验证

运行代码冻结后，以 detached worktree 的 `961c4d8` 加本次完整相关差异验证，另以相同源码归档验证最低 Ruby 和 Linux。
四组 `bash script/ci` 均退出 0：

| 环境                                        | 测试                                            | 其他检查                                                                                            |
|---------------------------------------------|-------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| macOS arm64，Ruby 3.4.11                    | 421 runs / 7,235 assertions，零失败、错误及跳过 | 71 文件 RuboCop；API/RBS；示例；五组 benchmark smoke；Gem 构建及普通/Bundler 隔离安装与真实本地 PTY |
| macOS arm64，Ruby 4.0.7                     | 同上                                            | 同上                                                                                                |
| Linux aarch64，Ruby 3.4.11，Docker bookworm | 同上                                            | 同上                                                                                                |
| Linux aarch64，Ruby 4.0.7，Docker bookworm  | 同上                                            | 同上                                                                                                |

日志为 `tmp/performance-review/ci-{macos34,macos40,linux34,linux40}.log`。Linux 禁用网络，从本地 Gem 缓存安装。
macOS 独立工作树首次命令误取系统 Ruby 2.6，未进入测试；显式指定 Homebrew Ruby 后才计入上表。
最后仅将新增 Redactor 长尾基准的默认样本增至 100 次，四环境均补验最终 benchmark smoke，macOS 两版本补验相应 lint。
运行库及安装包内容未因此改变；后续只补充性能、内部契约与本验证记录。

未运行远端 GitHub Actions、x86_64、真实 SSH/网络设备或持续生产负载；合成基准不是设备并发容量承诺。
版本仍为 0.6.0，修复记录于 Unreleased；没有新增提交、推送、标签或发布。

## 2026-09-30：0.6.0 深度自审与边界修复

以本地提交 `961c4d8` 为基线审查公开门面、Session 生命周期、匹配/转接状态机、日志脱敏、配置、RBS、CI 和包清单。
保留公开方法、参数、Result 返回和资源所有权契约；版本仍为 0.6.0，本轮修复记入 Unreleased，未提交或发布。

### 失败证据与修复

| 问题                       | 修复前复现                                                                                | 修复                                                              |
|----------------------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------|
| fork 后延迟启动子进程      | 父进程创建 PTY、fork 子进程再 spawn，wait 返回 nil 且 PID 残留；期望退出码 7 并清空 PID   | 登记 PID 时记录实际启动者，继承已有 PID 的副本仍保留原归属        |
| 启动错误被清理错误覆盖     | fork 失败遇错误管道关闭失败、exec 失败遇 master 关闭失败，均错误返回 IOError              | 复用 Cleanup.always 和逐端清理，保留原始 fork 错误及 SpawnError   |
| 会话/IO 值相等混淆身份     | 独立来源漏读、模式组错并、EOF 错派、就绪查询遗漏/多报；转接遗漏可写目标或选择错误停止来源 | 去重、分组、事件与就绪归属使用对象身份，保持声明顺序              |
| 混合转义跨次调用漏检       | 同时注册字面 STOPS 和正则 STOP，首轮 ST 超时发出，后续 OPtail 未触发正则退出              | 超时排出尾部同步补入正则历史，保留 tail 供恢复                    |
| 自定义 writer 返回非法哨兵 | listener.write 返回 :wait_writable 时未抛 IOError                                         | 仅真实 IO.write_nonblock 接受该哨兵，自定义 writer 仍校验字节计数 |

新增 13 条回归并扩展 1 条非法写入计数回归；对应缺陷均先观察修复前失败，再执行修复后验证。
真实管道和 fork 验证来源身份及子进程归属；故障注入验证清理错误优先级。可写唤醒用 Queue 协调，避免依赖固定 sleep。
独立复审确认日志/脱敏、不可变 Result、UTF-8 与字节窗口、期限及打包边界未出现新的可证实缺陷；不据此声称不存在其他问题。

### 完整本地验证

四组均执行项目 `bash script/ci`，退出码为 0：

| 平台                           | Ruby   | Minitest                                        | 其他门禁                                                                     |
|--------------------------------|--------|-------------------------------------------------|------------------------------------------------------------------------------|
| macOS arm64                    | 3.4.11 | 417 runs / 7,206 assertions，零失败、错误及跳过 | 71 文件 RuboCop、API/RBS、示例、五组 benchmark smoke、Gem 构建及隔离安装通过 |
| macOS arm64                    | 4.0.7  | 同上                                            | 同上                                                                         |
| Linux aarch64，Docker bookworm | 3.4.11 | 同上                                            | 同上                                                                         |
| Linux aarch64，Docker bookworm | 4.0.7  | 同上                                            | 同上                                                                         |

普通 RubyGems 与最小 Bundler 应用分别验证真实本地 PTY、运行时依赖、RBS 分发及开发文件未混入包。
最低 Ruby 和 Linux 使用相同源码快照，Linux 容器禁用网络并从本地缓存安装依赖；macOS 3.4 副本位于仓库之外，确认实际扫描了 71
个 Ruby 文件。
日志位于忽略目录 `tmp/deep-review/ci-{macos34,macos40,linux34,linux40}.log`。既有 Process 替换、宿主 RDoc
重定义及无依赖上限提示没有影响退出状态。

未运行远端 GitHub Actions、x86_64、真实 SSH/网络设备或完整性能评估。benchmark smoke 只证明小规模工作负载正确，不作为性能提升结论。
本节是本地源码与安装包验收记录，没有推送、打标签或发布 RubyGems。

## 2026-09-30：0.6.0 本地提交准备

将现有改动归入 0.6.0，更新版本常量、安装示例、迁移说明及发布文档，保留历史验证记录。

在 macOS arm64、Ruby 4.0.7、Bundler 4.0.20 上执行 `bash script/ci`：

- 404 tests / 7,150 assertions，零失败、错误及跳过；71 个 Ruby 文件 lint 通过。
- API 文档/RBS 覆盖检查、RBS validate、示例对话及五组 benchmark smoke 通过。
- 构建 `expect-pty-0.6.0.gem`，普通 RubyGems 与最小 Bundler 应用的隔离安装、运行时依赖和真实本地 PTY 验证通过。
- 对同一构建包执行 `script/release.rb --dry-run --rubygems-only --artifact tmp/ci/expect-pty-0.6.0.gem`
  ，版本、发布说明、包元数据及源码内容校验通过。

测试中有既有 Process 方法替换警告，构建时有宿主 RDoc 常量重定义警告；上述命令均退出 0。
本次仅验证当前 macOS Ruby 4.0.7 环境；此前 Ruby 3.4/Linux 的矩阵记录见下文，本次未重新执行。
本次操作仅用于本地 Git 提交，不推送 GitHub、不创建标签、不发布 RubyGems，也未执行远端 CI 或真实 SSH/网络设备验证。

## 2026-09-30：接口收敛与审查整改

在上一轮未提交工作树上继续实施。`expect` 统一返回 Result，移除 `expect_result` 和七个布尔普通 reader；
按用户要求保留 `before`、`after`、`match`、`match_number`、`captures`、`error`。
模式与分组在匹配前冻结，内部 Pattern 为私有 Data；修正 Result 构造与 callable 日志的 RBS，并补强 API 门禁。

本轮最终本地 `bash script/ci` 结果：

| 环境                           | Ruby   | 测试                                           | 风格及安装                                        |
|--------------------------------|--------|------------------------------------------------|---------------------------------------------------|
| macOS arm64                    | 3.4.11 | 403 runs / 7140 assertions，零失败、错误及跳过 | 71 Ruby 文件零 offense；普通/Bundler 隔离安装通过 |
| macOS arm64                    | 4.0.7  | 403 runs / 7140 assertions，零失败、错误及跳过 | 71 Ruby 文件零 offense；普通/Bundler 隔离安装通过 |
| Linux aarch64，Docker bookworm | 3.4.11 | 403 runs / 7140 assertions，零失败、错误及跳过 | 71 Ruby 文件零 offense；普通/Bundler 隔离安装通过 |
| Linux aarch64，Docker bookworm | 4.0.7  | 403 runs / 7140 assertions，零失败、错误及跳过 | 71 Ruby 文件零 offense；普通/Bundler 隔离安装通过 |

四组均通过 API 文档/签名覆盖检查、RBS validate、示例对话、五组基准 smoke、Gem 构建和安装后的真实本地 PTY 对话。
新增回归证明模块方法遗漏文档或签名、Result 构造签名缺失会使门禁失败；同时验证结果便捷读取、谓词配置、
回调内及等待后的规则冻结、callable 日志对象、Data 构造/复制和单字符串 shell/多参数 argv 行为。
日志位于本地忽略目录 `tmp/interface-review/ci-{macos34,macos40,linux34,linux40}-final.log`。

验证过程修正了本地快照携带 AppleDouble 文件及复制目录被 RuboCop 排除的环境问题，以上只统计修正后的最终运行。
测试替换 Process 方法产生既有重定义警告；部分环境的 RubyGems 构建产生 RDoc 重定义警告，均未影响退出状态或安装验证。
这是本地矩阵，未运行远程 GitHub Actions、真实 SSH/网络设备或完整性能评估；没有提交、推送、打标签或发布。
后续 CHANGELOG 仅合并 Unreleased 段落，验证记录仅追加本节，运行源码与最终矩阵一致。

## 2026-09-30：Ruby 3.4+ 现代化与 Session 内核

本轮基于 0.5.3 工作树，保留开始时 CHANGELOG、README、gemspec、expect.rb、script/ci 的依赖清理改动。
改造覆盖不可变 Result、独立 Session、Logging/Terminal/Interaction 模块、Cleanup 作用域、配置声明、类型文档和精简包。
版本保持 0.5.3，变更记录于 Unreleased；构建包仅供本地验收，没有提交、标签、推送或发布。

### 最终检查

| 环境                       | 完整 `bash script/ci`                                                                                                                  |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| macOS arm64，Ruby 4.0.7    | 394 测试 / 7,026 断言；70 文件 lint；API 文档/RBS 覆盖与签名验证；五组 benchmark smoke；Gem 构建及普通 Ruby/Bundler 隔离安装，全部通过 |
| macOS arm64，Ruby 3.4.11   | 同上，在 `/tmp/expect-modernization-macos34-final` 独立副本执行，70 文件确实参与 lint                                                  |
| Linux aarch64，Ruby 4.0.7  | 同上，现有 `ruby:4.0-bookworm` 容器独立源码副本及依赖                                                                                  |
| Linux aarch64，Ruby 3.4.11 | 同上，在上述 Linux 容器中从官方 Ruby 3.4.11 源码构建独立运行时                                                                         |

Linux Ruby 3.4.11 源码包 SHA256：`5c22be44524312b3d433d68739bcc530633b1da5ef8ba0afa0a37680da17d3de`，构建前已校验。
macOS 安装了 Homebrew ruby@3.4，未切换默认 Ruby；测试 Gem 依赖放在忽略目录下。
四种环境的 Ctrl-C 专项各重复 50 次通过；处理器退出码验证信号，不依赖可被终端刷新丢弃的输出。
第一次 macOS 3.4 副本位于仓库 tmp，RuboCop 因继承排除规则扫描 0 文件，因此该轮 lint **不计作证明**；上表采用移至 `/tmp`
后的完整复验。

最终日志：`tmp/modernization/ci-{macos40,macos34,linux40,linux34}-final.log`。
公开 Expect 实例方法与改前快照比较无新增/缺失；Result 的破坏性调整另见 MIGRATION。
YARD 的公开源码入口统计 100% 文档覆盖；额外门禁检查 Forwardable、布尔宏、Data 生成的实际公开方法。
RBS 验证只证明声明有效且覆盖公开方法，不代表全库方法体已经完成静态类型检查。
测试包含 GC 回收、初始化中断、原异常保留、短写恢复、嵌套匹配、转接重入拒绝、二进制/UTF-8 和脱敏。

### 性能与分配

同一 macOS Ruby 4.0.7，改前/后均 10 次迭代、3 个样本，表中使用中位数；耗时比小于 1 表示本次样本更快。
采样较小，耗时不作为稳定性能提升的结论。拆分中发现临时目标数组可避免，已合并遍历；多目标转接分配比基线减少约 4.5%。

| 工作负载                 | 改后/改前耗时 | 分配对象数（改前 → 改后） |
|--------------------------|---------------|---------------------------|
| `stream/1048576/literal` | 0.958         | 4,441 → 4,481             |
| `stream/1048576/regexp`  | 1.038         | 14,691 → 14,731           |
| `groups/32`              | 0.985         | 2,891 → 2,891             |
| `ready/32`               | 1.055         | 1,661 → 1,671             |
| `escape/none`            | 0.981         | 151 → 161                 |
| `escape/literal`         | 1.044         | 191 → 201                 |
| `escape/regexps`         | 1.029         | 811 → 821                 |
| `mixed_targets`          | 1.045         | 849,301 → 810,821         |

JSON 证据为 `tmp/modernization/{matching,relay}-{before,after}.json`；基线源码和原始差异同目录保存。

未执行远程 GitHub Actions、x86_64、真实 SSH/网络设备或发布。上述 Linux 容器不等同于 GitHub Ubuntu runner。

## v0.5.2 改进计划 T00–T07（2026-09-27，本地实施阶段）

以下是版本归档前的本地验证记录，对应改动随后归入 0.5.3。发布状态以 GitHub Release、对应 CI 和 RubyGems 为准。

基线为 `ac583532b5f4c946856e79ecd7350eb298019081`，开始时主工作区干净且 HEAD 等于本地 v0.5.2 标签。
本轮保留同步 IO、匹配优先级、默认 nil 期限、二进制缓冲及现有运行时依赖。版本仍为 0.5.2，变更记入 Unreleased；
没有提交、推送、创建标签、调用发布接口或登录真实 SSH。

T00 在 macOS 26.6.2 arm64、Ruby 4.0.6、Bundler 4.0.17、Minitest 5.27.0 上执行原始 `bundle exec rake`：
61 个文件 lint 通过，346 项 / 6,604 断言，退出码 0，无失败、错误或跳过。
系统默认 Ruby 为 2.6.10，因此下列本机命令统一使用 Homebrew Ruby，不改全局配置：

```sh
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export BUNDLER_VERSION=4.0.17
bundle exec rake
bundle exec rake test TESTOPTS='--seed=20260927'
bundle exec rake test TESTOPTS='--seed=1'
bundle exec rake test TESTOPTS='--seed=42'
script/ci
```

计划中的 `TESTOPTS='--seed 20260927'` 在锁定的 Rake 13.4.2 上实际失败：加载器把独立的数字参数当作文件。
同一 `rake test` 入口改用 `--seed=...` 后，输出确认采用指定 seed；未修改加载器、依赖或测试门槛。

### 按任务核对红灯与绿灯

从基线建立独立 detached worktree `tmp/improvement-052/baseline`，只复制对应的新回归测试，逐文件重放旧行为。
下表红灯为该基线的真实失败，绿灯为修复后同一测试文件的独立运行；全部使用 seed 20260927。

| 任务          | 修改与回归文件                                                                 | 旧版失败证据                                                                            | 修复后结果（测试 / 断言）            |
|---------------|--------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|--------------------------------------|
| T01 / F01     | `lib/expect.rb`、`session_resources.rb`、`test/initialization_failure_test.rb` | 6 项失败：PTY 未关闭、open 用 NoMethodError 覆盖原中断                                  | 6 / 39，通过                         |
| T02 / F02     | 上述生命周期文件、`test/process_interruption_test.rb`                          | 3 项失败、4 项错误：EINTR 提前终止 wait/close，finalizer 未 detach，归属变化后仍 detach | 12 / 56，通过                        |
| T03 / F03     | `lib/expect.rb`、`interaction.rb`、`relay.rb`、`test/relay_reentrancy_test.rb` | 5 项失败：`abc` 变为 `abcabc`、重叠来源未拒绝、准备异常丢失缓冲                         | 8 / 47，通过                         |
| T04 / F04     | `script/release.rb`、发布 workflow、`test/release_test.rb`                     | 2 项失败：中文说明在 US-ASCII 下无法解析，非法 UTF-8 缺少明确诊断                       | 21 / 124，通过（含原有发布拒绝条件） |
| T05 / C01–C02 | `lib/expect.rb`、`test/write_contract_test.rb`                                 | 2 项失败：零计数依赖 watchdog 才退出，超出当前 chunk 的计数未拒绝                       | 6 / 39，通过                         |
| T06           | `test/ownership_sequence_test.rb`                                              | 组合回归，非新增独立缺陷                                                                | 6 / 161，通过                        |
| T07           | README、内部契约、CHANGELOG、本记录                                            | 保留所有原测试及原有 CI 门禁                                                            | 见下方完整验证                       |

F01 使用真实 IO/PTY 并注入构造与 close 故障；F02 包含真实孩子的 waitpid 中断、真实 fork 非创建者检查，
连续中断和 GC 路径另外使用受控时钟与全部系统调用替身。假 PID 不进入真实信号或回收调用。
F03 使用公开 API、真实管道和自定义 writer 自然复现；F04 使用真实 CLI 子进程和中文文件。
C02 是非法 IO 适配返回值注入，不能推断正常 Ruby IO 会返回这些值。C01 的持续成功短写特征在旧版及新版均通过。

T06 的字节与多目标序列使用固定 seeds 20260927、1、42，核对各目标的完整内容、已确认计数、未处理缓冲、
转义消费、日志唯一性及原目标续发。真实 pipe EOF 与仍活跃孩子组合验证 IO/PID 相互独立，soft_close 只发 TERM，
hard_close 后读取真实状态并确认 ECHILD。测试时钟与系统调用替身在 ensure 中恢复，watchdog 仅用于测试防挂起。

### 完整验证与发布预演

新增 40 项测试，最终本机 `bundle exec rake`：66 个文件 lint 通过， **386 项 / 6,965 断言**，退出码 0。
三个固定 seed 的默认套件也各为 386 / 6,965，退出码均为 0，无失败、错误或跳过。
原有 cleanup/process/terminal_cleanup、relay/interact/diagnostics、io/timeout/deadline 定向组合也全部通过。

| 环境                                        | 完整 `script/ci`                       |
|---------------------------------------------|----------------------------------------|
| macOS 26.6.2 arm64，Ruby 4.0.6              | 退出 0；386 / 6,965；66 文件 lint 通过 |
| Linux aarch64，Ruby 3.2.11，`ruby:3.2`      | 退出 0；386 / 6,965；66 文件 lint 通过 |
| Linux aarch64，Ruby 3.3.12，`ruby:3.3`      | 退出 0；386 / 6,965；66 文件 lint 通过 |
| Linux aarch64，Ruby 3.4.10，`ruby:3.4-slim` | 退出 0；386 / 6,965；66 文件 lint 通过 |
| Linux aarch64，Ruby 4.0.6，`ruby:4.0`       | 退出 0；386 / 6,965；66 文件 lint 通过 |

Linux 验证以只读源目录挂载到临时容器，复制到独立 `/work` 后，使用同一 Gemfile.lock、Bundler 4.0.17 与
`BUNDLE_FROZEN=true` 执行原始 `script/ci`。3.4 slim 的 git 和构建工具仅安装在该临时容器。
完整脚本包含 dialogue 示例、matching/relay/send_slow/scaling/redactor 五组 smoke、Gem 构建、
普通 RubyGems 与最小 Bundler 消费方的隔离 PTY/核心契约/运行时依赖检查；所有这些步骤保留并执行。

在添加本轮 Unreleased 条目前，用本地完整源码构建的同一个 Gem 实际执行：

```sh
LC_ALL=C LANG=C ruby -EUS-ASCII script/release.rb --dry-run --artifact tmp/improvement-052/expect-pty-0.5.2.gem
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ruby -EUTF-8 script/release.rb --dry-run --artifact tmp/improvement-052/expect-pty-0.5.2.gem
```

两次退出 0、验证相同 Gem 字节，生成的中文 release-notes 逐字节相同。该候选只是中途本地验证物，不是可发布版本。
新增 CLI 测试另覆盖独立 fixture 项目的非法 UTF-8 拒绝，以及 C/UTF-8 两种外部编码；不会访问发布服务。
当前 Unreleased 保留本轮变更，正式发布前仍需维护者自行归档并选择版本，原有拒绝条件不绕过。
最后对当前工作区再次执行 C locale dry-run，按预期退出 1 并提示
`Move Unreleased changes into the versioned changelog before releasing`。

### 同类检查、兼容性与剩余范围

- 构造所有权：核对 new/open/spawn/stty 四条入口。new/open 补账本之前的兜底；spawn 继续委托 new，stty 保留已有独立兜底。
- 进程回收：核对主会话、finalizer、stty 正常等待与异常回收。主会话/GC 修复 EINTR；stty 继续使用自身阶段策略，不合并账本。
- 写入进度：核对直接 write、RelayWriter、logging.emit 三处。后两者已有计数验证，仅补直接 write。
- 发布文本：本地入口与 workflow 共用 UTF-8 读取，notes 显式 UTF-8 写出；ASCII 校验和与 Git/Gem 二进制比较保持原状。
- 内部命名：统一为 `cleanup(failed:)`、`close_resources`、`close_child`、`mark_eof`；库、测试和文档无旧私有入口调用或别名。
- 兼容性：同源活跃 Relay 现在明确报 `ReentrancyError`，异常适配计数报 IOError；普通顺序恢复、嵌套 Matcher、匹配顺序和期限默认值不变。

G1–G6 由上述红绿回归与实际 locale dry-run 覆盖；G7–G8 由默认套件及原始 CI 脚本覆盖；G9–G10 由契约回归、
聚焦 diff 和本记录覆盖。日志位于被忽略的 `tmp/improvement-052/`，含基线、逐项红绿、固定 seed、容器和 dry-run 输出。
测试迭代中修正了测试 helper 与 Minitest 同名方法/嵌套 stub 的冲突，以及 CLI fixture 必须随脚本根目录复制的问题；
这些测试支架错误不计入产品红灯证据，表中证据来自修正后的独立基线重放。

未执行 macOS Ruby 3.2/3.3/3.4、远端 GitHub Actions 的 ubuntu-24.04/macos-15 矩阵、真实 SSH 或发布。
本地 Linux arm64 容器不能替代该远端矩阵。T08 的长期压力、高水位及性能对照按计划留作后续测量；
本轮 smoke 不证明吞吐提升、峰值内存下降或任意系统故障下保证回收成功。

## 0.5.0 公共字节过滤器发布前复核（2026-09-27）

基线为已发布的 `5a219f7`（0.4.0）。本轮公开 `Expect::Redactor`，新增 11 项回归，覆盖独立加载不引入
PTY、完整文本与流尾部策略、跨分片与重叠秘密、自定义替换标记、空规则、输入复制、无效更新原子性及安全摘要；现有会话日志与诊断继续复用该过滤器。

从基线建立独立检出，仅带入本轮改动。macOS arm64、Ruby 4.0.6、Bundler 4.0.17 下执行 `ruby script/release.rb --dry-run`，330
项测试、1,894 条断言全部通过，无失败、错误或跳过；RuboCop 检查 59 个文件无违规。四组基准 smoke、Gem 构建、普通 RubyGems 与最小
Bundler 应用的隔离安装均通过，安装后实际调用公共完整文本和分块过滤接口。

此处记录本地发布预演；远端 Linux/macOS 与 Ruby 3.2/3.3/3.4/4.0 矩阵、标签及下载包校验，以 0.5.0 发布提交对应的 GitHub
Actions 与 Release 为准。

## 0.4.0 发布前复核（2026-09-27）

发布前新增七项回归：总期限在文本回调后到达时，已知 EOF
先于剩余活跃来源的超时派发；覆盖日志路径前交付旧尾部，冲刷失败不能提前截断新文件；嵌套诊断等待保留外层匹配结果；日志回调轮换目标时正确交接所有权；诊断回调新建或再次写入另一方向时，尾部仍交给旧目标。各项均先复现失败，再验证修复，纯相对超时行为保持不变。

从 `b5e9159` 建立独立检出，只带入本轮 30 个功能、测试、文档和版本文件，排除主工作区的其他格式化改动。macOS arm64、Ruby
4.0.6、Bundler 4.0.17 下执行 `ruby script/release.rb --dry-run`，319 项测试、1,820 条断言全部通过，RuboCop 检查 58
个文件无违规；四组基准 smoke、Gem 构建、两种隔离安装和新增接口检查均通过。

此处记录本地发布预演，远端矩阵、标签和发布产物以 0.4.0 对应提交的 GitHub Actions 与 Release 为准；下节保留改进阶段的双平台验证结果。

## 底层引擎补齐与模块注释（2026-09-27）

基线为已发布的 `b5e9159`（0.3.3），本节记录 0.4.0 发布准备前的底层改进验证。范围限于底层
Expect：裁剪计数、生命周期及错误契约、等待总期限、诊断目标、按字节流脱敏、增量字面扫描及多来源基准。未引入厂商实现、SSH 编排或新的
Reactor。

新增 43 项回归，覆盖外部回收、借用 IO、关闭重试、缓冲裁剪与正常消费、绝对期限限制各类重置、已知
EOF、EINTR、分片与重叠秘密、二进制诊断、流尾部交付，以及字面缓存与全量扫描的操作序列对照。

| 当前环境                                                         | 完整 `bash script/ci`                                            |
|------------------------------------------------------------------|------------------------------------------------------------------|
| macOS arm64，Ruby 4.0.6，Bundler 4.0.17                          | 312 项 / 1,784 条断言，0 失败、错误、跳过；RuboCop 58 文件无违规 |
| Linux aarch64，Ruby 3.2.11，Bundler 4.0.17，当前源码独立容器副本 | 同上；容器使用冻结锁文件及独立 Linux 依赖                        |

两套检查均通过对话示例、四组基准 smoke、Gem 构建、普通 RubyGems 和最小 Bundler 应用的隔离安装。安装后检查新增总期限、裁剪计数、内部过滤器和结构化诊断实际工作，并确认
Logger 等开发依赖没有泄漏到运行时。macOS 构建存在宿主 RDoc 7/8 重复常量警告，命令退出状态为 0。

审阅 `lib/expect` 全部 14 个模块，补齐其中 12 个模块的中文职责、方法及复杂流程注释；加载入口和版本文件保留现有充分说明。以注释编辑开始时的源码快照对照，15
个库文件的 Ripper 语法树（忽略位置）完全相同，逐行差异也仅为注释或空白。工作区其他 Ruby 格式化修正同样核对语法树等价。

另通过 14 个文档 Ruby 片段语法解析、工作流 actionlint（未启用 shellcheck）和 `git diff --check`
。两轮同机匹配性能对照、真实管道来源容量与阻塞目标检查见 [性能基准](PERFORMANCE.md#持续字面扫描验证2026-09-27)；1,000
管道来源只证明该受控场景，不代表真实设备吞吐或长期运行。

本轮未运行远端 CI、Ruby 3.3/3.4 或真实 SSH/设备测试，未提交、推送或发布。以下历史记录不作为本轮验收结果。

## 模块审查、资源清理与正则输入复用（2026-09-27）

基线为 `b9fc077`，以下为 0.3.3
发布准备前的源码审查记录。覆盖会话、配置、模式声明与定位、匹配结果及期限、资源所有权、日志、终端、人工接管、转接恢复、示例、发布和打包模块。修复工厂/构造失败后的子进程回收、部分句柄清理、原始异常保留、EOF
继续期限和发布包提交来源验证；新行为均有先失败后通过的回归。EOF 补充多源同时结束和重置期限用例，保留已知 EOF 的派发顺序。

日志与终端方法拆入独立能力文件，公共入口保持 `expect/pty`；打包检查确认两文件随 Gem
分发。正则输入复用通过冻结输入、编码分片、二进制、字节偏移及匹配/转接回归，实测数据见 [性能基准](PERFORMANCE.md#正则输入复用验证2026-09-27)。

| 当前运行环境                                             | 完整 `bash script/ci`                                          |
|----------------------------------------------------------|----------------------------------------------------------------|
| macOS arm64，Ruby 4.0.6，Bundler 4.0.17，原工作区        | 269 项 / 1,356 断言，0 失败、错误、跳过；RuboCop 51 文件无违规 |
| macOS arm64，同一运行时，隔离 worktree                   | 同上；从基线加本轮补丁及新增文件重建                           |
| Linux aarch64，Ruby 3.2.11，Bundler 4.0.17，独立容器副本 | 同上；冻结开发锁文件，容器独立安装依赖                         |

三次均完成对话示例、三组基准 smoke、Gem 构建、普通 RubyGems 与最小 Bundler 应用的隔离安装及真实 PTY 对话。另检查包内 69
个文件及新增模块，无构建目录或日志；工作流 actionlint 通过（未启用 shellcheck），发布与示例 `--help` 正常。macOS 构建仍有宿主
RDoc 7/8 重复常量警告，退出状态为 0。

发布测试使用临时 Git 仓库，验证合法包通过，忽略文件、`assume-unchanged` 隐藏内容、忽略执行权限变化及主页元数据不一致均被拒绝，未连接发布服务。审查时版本仍为
0.3.2，改动位于 `Unreleased`，这些本地检查不代替发布验证；当时未运行真实 SSH、远端 CI 或 Ruby 3.3/3.4，也未提交、推送或发布。0.3.3
的远端平台结果以发布提交对应的 GitHub Actions 为准，以下历史结果不作为本轮验证证据。

## 配置并发与模块审查改进（2026-09-26）

当前工作树在既有未提交的匹配、转接和清理改动上，增加 `configure` 的串行读改写与回归测试：旧实现的并发用例先失败，修复后通过；嵌套调用显式抛出
`ThreadError`，不会陷入死锁或发布部分配置。`read_available` 的裁剪选择改为显式参数，转接调用明确禁止裁剪其待处理缓冲。RuboCop
对生产代码启用分支复杂度检查，既有状态机只在对应方法局部豁免；补充内部调用契约、贡献指南、issue/PR 模板与安全说明。

macOS arm64、Ruby 4.0.6、Bundler 4.0.17 下执行 `bash script/ci`：249 项测试、1,242 条断言，0 失败、错误或跳过；RuboCop 检查 49
个文件无违规。对话示例、三组基准 smoke、Gem 构建、普通 RubyGems 与 Bundler 隔离安装及真实 PTY 对话均通过。构建时本机 RDoc 7/8
重复常量警告仍存在，但命令成功完成。

本轮未运行 Linux/Ruby 3.2、远端 CI 或真实 SSH；未提交、推送或发布。下文历史结果不作为本轮检查证据。

## 0.3.0 发布前复核（2026-09-26）

以 0.2.0 为基线导入源码更新，发布前增加 8 项回归，覆盖退出正则切换、同规则跨次匹配、待发送恢复、跨次
CRLF、转义回调内匹配与异常尾部恢复、嵌套写入超时进度。新用例先在修复前失败，再验证修复；仅内部转义处理器的两项测试随职责调整更新调用方式。

macOS arm64、Ruby 4.0.6、Bundler 4.0.17 下执行 `BUNDLER_VERSION=4.0.17 bash script/ci`：225 项测试、903 条断言，0
失败、错误或跳过；RuboCop 检查 42 个文件无违规，对话示例、Gem 构建、隔离安装及 PTY 对话全部通过。连续 1,000 次使用同一输入调用
`interact`，仅保留一个输入包装器，关闭会话不关闭借用 IO。

真实 IO 的已有 Ruby 写缓冲可能让 `write_nonblock` 先阻塞刷新，已在 README 明确首次写入前设置 `sync`
或交接前排空缓冲的要求；未通过绕过缓冲改变字节顺序。真实 SSH 与完整上游差分不在本次验证范围。远端平台矩阵以发布提交对应的
GitHub Actions 结果为准，以下记录属于各自历史时点。

## 转接期限、交付恢复与输入接续（2026-09-26）

继续引用审查中的 R1–R5，在原有未提交改动上修复；基线为 194 项测试 / 737 条断言全部通过。新增 `test/relay_recovery_test.rb`
的前 8 个用例先在未修复实现运行，得到 5 个失败、3 个错误，分别确认阻塞超时、部分发送重放、监听器失败重放、短写入丢后缀、原始输入
IO 接续、背压读取 EINTR、写超时进度和 EOF 截断编码问题。修复后这 8 项通过，再扩展到 23 项恢复与边界用例。

根因与修复：

- `interconnect` 的期限原先只约束读取循环，同步 `target.write` 可以无限阻塞；`Relay` 现统一 select
  读写并保留总期限，超时后的前缀刷新也只尝试非阻塞写入。
- 原先只有单次 `write` 的局部偏移，转发失败后重新发送整个源缓冲；`RelayWriter` 现按目标保留游标，成功目标不重放，短写入继续后缀，flush
  异常只重试 flush。转义回调等待前缀交付，剩余输入与待发送数据分别保留。
- `interact` 原先每次新建输入包装器；现由连接持有并按原始 IO 身份复用，关闭连接时不等键盘 EOF、不关闭借用
  IO。关闭路径也先通过有界测试复现等待，再修复并复验。
- 背压读取的 `EINTR` 纳入原写期限重试；直接写超时异常提供 `bytes_written`。编码检查感知 EOF，固定 UTF-8 正则对截断字符抛出
  `EncodingError`，匹配缓冲保留原字节。

同类路径复核覆盖直接写入、转接的常规/转义/EOF/超时发送、日志及普通监听器的 `emit`、匹配和转义两处正则定位。共同 `emit`
同样补齐短写入检查；匹配和转义都传入 EOF 状态。日志、回调、普通匹配的监听器以及自定义写入对象仍同步运行，文档明确这些操作不受
IO 等待期限强制中断；自定义对象必须准确返回已接受的字节数。R6 使用 Ruby 已有的正则实例
timeout，新增测试验证异常透传、缓冲保留及全局配置不变，未增加进程全局设置。

| 环境                       | 完整 `script/ci`                                             | 打包及运行                                      |
|----------------------------|--------------------------------------------------------------|-------------------------------------------------|
| macOS arm64，Ruby 4.0.7    | 217 项 / 857 断言，0 失败、错误、跳过；RuboCop 42 文件无违规 | 对话示例、Gem 构建、隔离安装及真实 PTY 对话通过 |
| Linux aarch64，Ruby 3.2.11 | 217 项 / 857 断言，0 失败、错误、跳过；RuboCop 42 文件无违规 | 对话示例、Gem 构建、隔离安装及真实 PTY 对话通过 |

Linux 从 gemspec 文件白名单及锁文件构造独立源码快照，只读挂载后复制到容器，使用 Bundler 4.0.20、锁定依赖及
`BUNDLE_FROZEN=true`；未读取或分发工作区设备日志。检查构建包包含 `relay.rb`、转接写入器（现名 `relay_writer.rb`
）、原有重命名模块和新增回归测试，不含 `tmp/` 或 `.git/`。macOS 构建时存在本机 RDoc 多版本重复常量警告，命令成功退出，隔离安装与
PTY 验证通过。工作区原有 16 处样式问题只作相应格式修正。

Linux 首轮新增用例误把 0.1 秒转接超时当作发送完成：`pending_output? == false` 时，`buffer`
仍可能含尚未排入队列的输入。探针证实该状态存在；用例改为关闭源写端并等待转接返回该 EOF 来源，明确验证缓冲已空后再断言回复，避免依赖机器吞吐量。

`git diff --check` 通过。未运行 Ruby 3.3/3.4、远端 CI 或真实
SSH；未提交、推送或发布。新增源码仍需随现有重构文件一起纳入后续提交。性能窗口、完整输出存储等建议已补充使用说明，未改变默认缓冲上限或任意正则的匹配语义。

## Tcl 对照与全项目复核（2026-09-26）

基于 `e6fc883` 及当前全部未提交改动，复核库源码、测试、示例、打包和发布脚本。保留既有 `Matcher`、`SessionResources` 和
`interaction.rb` 职责命名，不新增兼容别名。本轮补充四项回归测试，修复三处问题：

- Ruby 编码转换器识别非法 UTF-8 前缀，避免将过长编码、代理区或越界码点误判为等待更多字节；合法分片继续等待，原字节保留。
- 转接读取先存入转接缓冲，再调用日志；日志异常后输入归还会话，可继续匹配。
- 新建日志使用 `0600` 权限；追加和覆盖已有文件均保留其权限。

三项缺陷均先运行回归测试确认旧实现失败，再修改实现并复验。合法分片用例覆盖二、三、四字节字符的每个截断位置。

| 环境                       | 完整 `script/ci`                                             | 打包验证                                    |
|----------------------------|--------------------------------------------------------------|---------------------------------------------|
| macOS arm64，Ruby 4.0.7    | 191 项 / 728 断言，0 失败、错误、跳过；RuboCop 39 文件无违规 | 对话示例、构建、隔离安装与真实 PTY 对话通过 |
| Linux aarch64，Ruby 3.2.11 | 191 项 / 728 断言，0 失败、错误、跳过；RuboCop 39 文件无违规 | 对话示例、构建、隔离安装与真实 PTY 对话通过 |

macOS 验证目录从 `git archive HEAD`、全部工作区补丁及未跟踪源码重建，包含本地开发锁文件；隔离的 GEM_HOME 安装 Bundler
4.0.17，并以 `BUNDLE_FROZEN=true bash script/ci` 验证，未依赖本机损坏的 Bundler 启动器。Linux 使用 `ruby:3.2-bookworm`
，源码只读挂载并复制到容器临时目录，同样安装锁定依赖；完整测试包含 `release_test.rb`。

核对 Tcl 官方 `expect.c` 的匹配、缓冲消费和继续计时流程，以及 `exp_inter.c` 的部分模式匹配和终端恢复；另在 Tcl Expect
5.45.4 与本库中分别实跑缓冲消费、保留、EOF 和 wait
场景，均通过。功能差异和未实现能力见 [接口说明](COMPATIBILITY.md#tcl-expect-语义边界)，不代表完整 Tcl 差分验收。

本轮未重跑真实 SSH、Ruby 3.3/3.4 或远端 CI，也未提交、推送或发布。以下记录保留各自验证时点，不作为本轮执行证据。

## 当前工作区：交互、匹配与 IO 修复（2026-09-24）

本轮检查并修复固定 UTF-8 正则在末尾字符未收齐时提前匹配、正则转义历史窗口截断到 UTF-8 续字节，以及就绪查询、写入和转接中的
`EINTR`。新增回归覆盖分片字符、历史窗口和 select/read/write 中断。

| 环境                      | 测试结果                              | 其他检查                                               |
|---------------------------|---------------------------------------|--------------------------------------------------------|
| macOS arm64，Ruby 4.0.7   | 187 项 / 692 断言，无失败、错误、跳过 | RuboCop 39 个文件无违规；对话示例通过                  |
| Linux aarch64，Ruby 4.0.6 | 176 项 / 658 断言，无失败、错误、跳过 | 只读挂载源码；排除依赖本机打包环境的 `release_test.rb` |

`git diff --check` 通过。本轮未在 Ruby 3.2 重新运行完整测试，也未运行远端 CI；下节的 Ruby 3.2 结果属于 2026-09-12
的历史验证，不能代表当前工作区。

## Ruby 原生接口与关闭策略（2026-09-12）

此次重构以 144 项测试 / 526 个断言为基线。原有交互场景全部迁移到新接口，新增 18 项回归，三个环境均通过 `bundle exec rake`
（RuboCop 和完整测试）及 `ruby examples/dialogue.rb`：

| 环境                       | 测试结果                              | RuboCop           |
|----------------------------|---------------------------------------|-------------------|
| macOS arm64，Ruby 4.0.6    | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |
| Linux aarch64，Ruby 3.2.11 | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |
| Linux aarch64，Ruby 4.0.6  | 162 项 / 618 断言，无失败、错误、跳过 | 37 个文件，无违规 |

新增检查覆盖配置发布的原子性、冻结与会话隔离、子类覆盖、无效赋值保留状态、Ruby
真值、字面模式标志、全部活跃会话的超时回调、重复超时注册、日志所有权。真实子进程验证软关闭收集尾部、响应 TERM、绝不发送
KILL、保留存活 PID、后续硬关闭和重复回收，以及自动清理、日志异常和无效关闭期限。模拟 EINTR 检查重复 select 中断不能延长期限、读取中断不丢输入。

最终会话输出接口统一为 `puts`、`write` 和 `send_slow(..., delay:)`，移除会话 `print` 和 `write_slow`。`lib/expect/` 的 9
个模块文件及主入口均补充中文注释，说明方法用途、匹配状态机、编码分片、转接缓冲、日志所有权和进程关闭；词法检查确认注释增补没有改变可执行代码。

原有 PTY、控制终端、信号、中文/二进制、背压、捕获组、匹配优先级、多会话、日志、interact 和 GC
测试继续全量运行。模块设置已收敛到配置对象；旧方法、位置超时、数组回调和 Perl 正则模式解析已移除，测试使用新 API。10 个文档
Ruby 示例块均通过语法检查。

macOS 的独立 `bundle exec rake test:kibitz` 也通过全部 6 个场景，报告位于
`tmp/kibitz/20260911T232907Z-20260912-9935-te8xfa/report.json`。本轮在 Linux Ruby 3.2 容器中重新运行
`test/compare_upstream.rb`， **11 组共同交互行为对照通过**；适配脚本使用新 Ruby API，显式转换错误标记及可读会话索引，原版
Perl fixture 未修改。

关闭策略另核对上游 `lib/Expect.pm` 的 `soft_close`、`hard_close` 和 `DESTROY`：软关闭最多 TERM，硬关闭可 KILL，销毁可先软后硬。Ruby
以 `graceful_close` / `close(graceful:)` 表达默认策略，以关键字配置等待期限；显式关闭返回 `Process::Status`，通用 `close`
返回 `nil`。

Linux 源码以只读方式挂载，使用 `BUNDLE_FROZEN=true` 和独立容器依赖目录；镜像摘要仍为下文记录的 `ruby:3.2` 与 `ruby:4.0`
。Gemfile 和锁文件未改动，锁文件 SHA-256 为 `b1186a77057fba44bb79c440ffb6921042c16c1b88d213fabaa6548befb38d57`。macOS 复用了
`/tmp/expect-pty-gems` 的隔离依赖环境。

本轮没有重新连接真实 SSH 或运行远端 CI。`pkg/` 的 0.1.0 / 0.1.1 构建与记录仍代表历史版本；当前源码的接口见 README 和
COMPATIBILITY。以下各节保留其原验证时间、接口和范围，不作为当前接口的使用说明。

## 历史验证记录

验证日期：2026-09-11。上游参考版本 Expect.pm 1.38，提交 `2ea0e4ce20a896c95cb4c94e781f1b1f3145150d`。

## 自动测试

完整测试集包含 76 项测试，全部通过，无跳过：

| 环境                       | 结果      |
|----------------------------|-----------|
| macOS arm64，Ruby 4.0.6    | 76 项通过 |
| Linux aarch64，Ruby 3.2.11 | 76 项通过 |
| Linux aarch64，Ruby 4.0.6  | 76 项通过 |

Linux 使用官方 Docker 镜像：

- `ruby:3.2`：`sha256:d3bcbd845d26ae1efafcc987f641aa9ac796267b9b857e0f196a2b05070c8330`
- `ruby:4.0`：`sha256:8dc3950712ad2078bdd275b890419ba2fd3aab5a0653b291a7325f0d8a24ca05`

测试范围包含真实 PTY 的控制终端、stdin/stdout/stderr、raw/noecho、终端尺寸、Ctrl-C 前台信号、退出码、TERM/KILL 回收、GC
兜底；模式优先级、捕获组、中文分片、二进制、缓冲上限；回调、事件、绝对/接收重置超时；多会话、日志、管道和 socket、大块双向
IO、写入背压；人工交互、跨读取转义序列、异常和超时后终端恢复；与 Ruby 标准库 IO#expect 共存。

macOS 改变终端设置后内核可能设置 PENDIN 临时状态位。终端恢复测试屏蔽这一状态位，比较其余完整配置；没有忽略真实的
echo、canonical、输入/输出、信号或控制字符设置变化。

复现：

```sh
bundle install
bundle exec rake test
```

本机全局 RubyGems/Bundler 安装存在版本混用，验证使用了临时 GEM_HOME 中的独立 Bundler 4.0.16、Rake 和 Minitest；未修改项目对
Bundler 的通常用法或用户的全局 gem。

## 上游差分验证

`test/compare_upstream.rb` 对同一输入分别运行原始 Perl 模块与本 Ruby
实现：字面模式、数组正则、跨行锚点、模式优先级、notransfer、缓冲上限、超时保留缓冲、连续回调、真实 PTY 对话。 **9 组对照通过**。

对照在 Linux Ruby 3.2 容器内执行，Perl 依赖 IO::Pty / IO::Stty 仅安装到该临时容器。正则捕获及错误访问的 Perl
对象模型差异见兼容性说明；没有将它们伪装为一致行为。

```sh
# 此项是可选验证，需要 Perl 及 IO::Pty / IO::Stty。
ruby test/compare_upstream.rb /path/to/expect.pm
```

没有把这 9 项差分测试等同于运行完整 Perl 上游测试套件；功能覆盖同时依赖 Ruby 的 76 项测试和源码/API 对照。

## 真实 SSH

使用用户授权的 `crate@127.0.0.1` 完成真实 OpenSSH 密码认证，进入远端交互 shell 和 PTY。校验随机输出标记、`id -un` 返回
`crate`、`tty` 返回 `/dev/...`，随后 `exit`，SSH 退出码为 0。

测试随机标记由远端拼接，排除了仅匹配命令回显的误判。密码由隐藏输入读取或从进程环境取出，只保留在验证进程内，未写入源码、测试、文档和日志。临时
known_hosts 在退出后删除。

```sh
SSH_USER=crate SSH_HOST=127.0.0.1 ruby examples/ssh_login.rb
```

## 打包和范围

提供 `expect-pty.gemspec`、MIT LICENSE、中文 README、API 兼容性表、对话和 SSH 示例，以及 macOS/Linux 的 Ruby 3.2/3.3/3.4/4.0
CI 配置。CI 文件已进行 YAML 解析检查，远端 GitHub Actions 尚未运行。

初始构建物为 `expect-pty-0.1.0.gem`，补充后的交付版本为 `expect-pty-0.1.1.gem`，包含可运行的测试和 fixtures。安装验证在独立
GEM_HOME 中、从项目目录外运行 `require "expect/pty"` 和真实 PTY 对话，避免依赖源码目录的加载路径。

原生 Windows、其他 Unix、真实外部设备/外部 SSH 服务未实测。没有发布 gem、推送仓库或创建远端 Release；本次交付为本地源码和安装包。

## 补充验证：登录后多脚本与日志（2026-09-11）

新增 `test/script_logging_test.rb` 的 8 项真实 PTY 测试，及可单独运行的 `test/integration/ssh_scripts.rb`。自动测试总计从
76 项增至 84 项。新增测试共享 5 个 `.sh` fixture，覆盖多脚本日志文件、回调和借用 File、日志出错、异常退出码、输出不符、引号和中文传输，以及超时后的日志连续性。

最终全量回归：macOS Ruby 4.0.6 为 84 项 / 283 断言，Linux Ruby 3.2.11 为 84 项 / 283 断言，Linux Ruby 4.0.6 为 84 项 / 289
断言，均无失败、错误或跳过。Rake 的 `test:ssh` 入口已注册，Ruby 脚本和 5 个 shell fixture 的语法检查通过。

真实 SSH `crate@127.0.0.1` 已通过同一会话内的 7 项执行（5 个文件脚本，加日志关闭/恢复用例）及 11 项日志检查。第 4 个 fixture
故意返回 7，第 5 个仍执行成功；最终 SSH 退出码为 0。日志读取验证包含执行期间即时 flush、逐条顺序、无重复、覆盖/暂停/追加，以及
`soft_close` 收集最终延迟输出。

实际通过的日志和 JSON 报告保存在 `tmp/ssh-logs/20260911T124918Z-20260911-97383-lka948/`。目录被 Git
忽略，每次重跑生成新目录，失败时保留失败报告。

该成功会话日志共 1633 字节，SHA-256 为 `6b8abf4df93e1c40dec21a2b89c359bf4e2a9f9636791a83713150af5796672c`，与 JSON
报告的摘要一致；日志和报告均为 0600 权限。`pkg/` 中保留 0.1.0 作为初始构建记录，后续修正和测试脚本随 0.1.1 打包。

## 完整性复核与 0.1.1

复核上游实际代码后，补充 `test_handles(timeout, *sessions)` 等待语义，以及 `set_seq` 正则序列和跨读取回调，差分用例从 9
组扩展到 11 组。新增回归也覆盖从 `expect` 切换到 `interconnect` 再返回时的日志唯一性、转义后的原始日志，以及日志目标抛 IO
错误时保留输入并正确报告错误。

0.1.1 包含库源码、中文文档、完整测试与 5 个 `.sh` fixtures、Gemfile、gemspec 和 Rakefile。具体构建摘要和安装后的验证结果记录在构建物旁的
`pkg/VERIFICATION-0.1.1.txt`，避免文档与包自身摘要循环依赖。

SSH 首轮测试曾准确报告中文脚本退出 127；根据日志定位到测试 helper 的逐字节转义与远端 shell 行编辑相互影响。已改为完整脚本单引号传输，并禁用交互
shell 的 emacs/vi 编辑；重跑后中文、标准输出和错误输出逐字节匹配通过。

## 补充验证：interact 与本地 Kibitz（2026-09-11）

当前源码全量测试为 **109 项**，无失败、错误或跳过：macOS arm64 Ruby 4.0.6 为 380 断言，Linux aarch64 Ruby 3.2.11 为 380
断言，Linux aarch64 Ruby 4.0.6 为 386 断言。Linux 仍使用上文记录的两个镜像。这些新增内容记在 Unreleased，已有 0.1.1
构建记录保持为该包的历史验证结果。

新增 7 项 `test/interact_test.rb` 测试覆盖真实 PTY 接管、输入即时回显、远端 Ctrl-C、两次 Ctrl-]
返回、恢复自动化、超时/EOF/回调和输出异常后的终端恢复。另补 1 项 CRLF 输出分帧回归，检查空输出、无末尾换行和多个末尾换行。人工交互启用远端
echo，回到自动化时关闭 echo；自动脚本的无回显设置保留。TTY 身份探测的换行匹配不参与输出截取，不存在同一分帧问题。

实际 SSH `crate@127.0.0.1` 通过的三条路径，均记录 SSH 退出码 0，日志与报告权限 0600：

| 路径              | 结果                                                       | 报告所在目录                                              |
|-------------------|------------------------------------------------------------|-----------------------------------------------------------|
| 自动 PTY 交互     | 4 项命令、13 项交互/日志检查                               | `tmp/ssh-interact/20260911T131311Z-20260911-367-hkxq5z/`  |
| 人工输入后 Ctrl-] | 回车前可见 `printf` 输入，执行结果正确，返回后自动命令成功 | `tmp/ssh-interact/20260911T131343Z-20260911-423-7pgq5m/`  |
| 人工直接 exit     | 远端 EOF、终端恢复、正常退出，不执行自动化恢复命令         | `tmp/ssh-interact/20260911T132040Z-20260911-1777-qi6yry/` |

参考上游 `examples/kibitz` 源码的连接图，新增 `examples/kibitz/kibitz.rb` 和 `test_kibitz.rb`。本地示例通过 Unix socket
连接两份 CLI，各自运行于独立真实 PTY；共享模式启动真实 shell。`test/kibitz_test.rb` 新增 7
项测试，覆盖共享状态、输入回显、双向广播、中文/stderr、Ctrl-C、无子进程互传、自定义分片转义、禁用转义、非零退出、连接与转接超时、日志唯一性以及终端恢复和
socket 清理。

测试捕获并修正了就绪提示先于本地 raw/noecho 设置的启动时序问题；现在两端的就绪提示均在终端设置完成后发送。分片转义检查先确认普通前缀已到达对端，再发送转义的剩余部分，确保确实覆盖跨读取路径。

`bundle exec rake test:kibitz` 独立执行 6 个场景并全部通过，报告保存于
`tmp/kibitz/20260911T132223Z-20260911-2081-1poaup/report.json`，每个场景有独立 `session.log`
。此验证参考并重现上游的本地交互行为，不代表移植或运行了上游的用户邀请、跨主机 rlogin 和转义菜单。

## Ruby API 与编码规范重构（2026-09-12）

本轮基线为 109 项测试 / 380 断言。新增 `test/ruby_api_test.rb` 的 35 项测试 / 146 断言，最终三种环境均通过完整的
`bundle exec rake` 和 `ruby examples/dialogue.rb`：

| 环境                       | 完整测试                              | RuboCop           |
|----------------------------|---------------------------------------|-------------------|
| macOS arm64，Ruby 4.0.6    | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |
| Linux aarch64，Ruby 3.2.11 | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |
| Linux aarch64，Ruby 4.0.6  | 144 项 / 526 断言，无失败、错误、跳过 | 35 个文件，无违规 |

新增验证覆盖简洁 `expect(10) { on(...) ... }`、显式块参数保留调用方 `self`、闭包、可选块参数、注册时异常和 `break`
不消费输入、关键字与位置超时校验、EOF / 超时 / 多会话回调、继续等待及原期限；也覆盖借用和接管 IO 的块清理、初始化失败、缓冲和监听列表副本、日志块、原生
`puts` 的空参数/嵌套/递归数组、对象写入与链式追加。

`Result` 转换验证直接对照七个 Struct 字段，包括 `to_a`、`Array(result)`、`to_h`、位置/键模式解构及显式多重赋值；确认不再响应
`to_ary`。另验证 `session.send(:buffer)` 等 Ruby 反射调用和实际字节写入分离。原有 PTY、二进制、超时、进程回收、日志、interact、Kibitz
测试继续全量运行。

开发依赖固定在 Ruby 3.2 可运行的范围：RuboCop 1.89.0、parallel 1.28.0、Minitest 5.27.0、Rake 13.4.2，锁文件已补齐校验和。Linux
验证以只读方式挂载源码，使用 `BUNDLE_FROZEN=true` 安装同一锁文件；镜像仍为本文记录的 `ruby:3.2` 和 `ruby:4.0`。macOS 使用
`/tmp/expect-pty-gems` 中的独立 Bundler 4.0.16。

调用与迁移说明已同步至 README、兼容性表和示例；`send(data)` 需改为 `write(data)`，多重赋值需显式使用 `result.to_a`，`puts`
返回 `nil`。不冲突的 Expect.pm 入口继续作为兼容入口保留。本轮未重新连接真实 SSH、运行 Perl 上游差分或触发远端
CI；历史验证记录不作为这些路径本轮实测的证明。
