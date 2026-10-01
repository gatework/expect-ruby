# frozen_string_literal: true

require "pty"
require "io/console"
require "stringio"
require "forwardable"
require_relative "expect/version"
require_relative "expect/configuration"
require_relative "expect/result"
require_relative "expect/session_resources"
require_relative "expect/pattern"
require_relative "expect/pattern_list"
require_relative "expect/matcher"
require_relative "expect/cleanup"
require_relative "expect/session"

# 自动化交互会话：可以拥有一个 PTY 子进程，也可以适配已有可 select 的 IO。
# 缓冲和匹配统一保留原始字节，配置、匹配结果与资源生命周期分别管理。
class Expect
  # 回调控制符：分别表示重置期限后继续，或保留原期限继续。
  CONTINUE = :continue
  # 继续等待但不重置相对期限。
  CONTINUE_WITHOUT_RESET = :continue_without_reset
  # 单轮非阻塞读写的最大字节数。
  # @api private
  READ_SIZE = 16_384
  CONFIGURATION_MUTEX = Mutex.new
  private_constant :CONFIGURATION_MUTEX

  # PTY 创建后命令启动失败。
  class SpawnError < StandardError; end
  # 同一个来源不能同时交给两个 Relay。
  class ReentrancyError < StandardError; end

  # 已被底层接受的字节不可撤回；调用方可据此只处理尚未写出的后缀。
  class WriteTimeout < IOError
    attr_reader :bytes_written

    # 记录本次已经确认交付的字节数，不推测异常写入是否产生副作用。
    # @param bytes_written [Integer] 已交付字节数。
    def initialize(message = "write timed out", bytes_written: 0)
      @bytes_written = bytes_written
      super(message)
    end
  end

  class << self
    # 读取冻结的默认配置；子类未单独配置时继承父类快照。
    # @return [Expect::Configuration] 冻结的类级默认快照。
    def configuration
      return @configuration if defined?(@configuration)
      return superclass.configuration unless self == Expect

      CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new.freeze }
    end

    # 基于旧快照构造可修改副本，全部赋值与配置块成功后才发布，异常时保留原配置。
    # 配置关键字覆盖默认值，未知键抛出 ArgumentError。
    # @yieldparam configuration [Expect::Configuration] 发布前可修改的副本。
    # @return [Expect::Configuration] 新发布的冻结快照。
    def configure(**)
      raise ThreadError, "nested configure is not supported" if CONFIGURATION_MUTEX.owned?

      # 初始化默认快照后，将整个读改写过程串行化，避免并发配置丢失更新。
      configuration
      CONFIGURATION_MUTEX.synchronize do
        updated = Configuration.new(**configuration.to_h, **)
        yield updated if block_given?
        @configuration = updated.freeze
      end
    end

    # 创建并启动会话；有块时返回块结果并确保关闭，无块时由调用方负责生命周期。
    # @param command [Array<String>] 命令及参数；单字符串遵循 Ruby 自动 shell 语义，多参数按 argv 执行。
    # @param env [Hash<String, String, nil>] 子进程环境覆盖。
    # @param chdir [String, nil] 子进程工作目录。
    # @yieldparam connection [Expect] 自动关闭的用户会话。
    # @return [Expect, Object] 无块返回会话，有块返回块结果。
    def spawn(*command, env: {}, chdir: nil, **)
      connection = nil
      spawned = false
      cleanup = -> { connection&.close(graceful: spawned && connection.graceful_close?) if block_given? || !spawned }
      Cleanup.always(cleanup) do
        connection = new(**)
        connection.spawn(*command, env:, chdir:)
        spawned = true
        block_given? ? yield(connection) : connection
      end
    end

    # 适配已有 IO；own: true 接管关闭责任，初始化失败也释放所属端点。
    # @param io [IO] 可 select 的真实读端。
    # @param writer [IO] 写端，默认与读端相同。
    # @param own [Boolean] 是否取得 IO 关闭责任。
    # @yieldparam connection [Expect] 自动关闭的用户会话。
    # @return [Expect, Object] 无块返回会话，有块返回块结果。
    def open(io, writer: io, own: false, **)
      connection = nil
      initialized = false
      cleanup = lambda do
        if connection && (block_given? || !initialized)
          connection.__send__(:cleanup_session, io, writer:, own:,
                                                    graceful: initialized && connection.graceful_close?)
        end
      end
      Cleanup.always(cleanup) do
        connection = allocate
        connection.__send__(:initialize_session, io, writer:, own:, **)
        initialized = true
        block_given? ? yield(connection) : connection
      end
    end

    # 按 listeners 建立转发图，返回引发停止的用户会话或 nil。
    # @param connections [Array<Expect>] 转接来源，不能为空。
    # @param timeout [Numeric, nil] 总等待秒数，nil 无限。
    # @return [Expect, nil] 停止来源；总期限到达返回 nil。
    def interconnect(*connections, timeout: nil)
      raise ArgumentError, "interconnect requires Expect sessions" unless connections.any? && connections.all?(Expect)

      Relay.new(connections.map { |connection| Session.for(connection) }, timeout).run&.connection
    end

    # 多会话等待的完整结果入口；from: 提供默认来源，块内可分别指定每个模式的来源。
    # @param patterns [Array<String, Regexp, Symbol>] 文本模式、:eof 或 :timeout。
    # @param timeout [Numeric, nil] 相对秒数，nil 无限，0 非阻塞轮询。
    # @param deadline [Numeric, nil] 单调时钟绝对期限，不被回调延长。
    # @yieldparam patterns [Expect::PatternList] 有参数块接收构建器；无参数块以 DSL 执行。
    # @return [Expect::Result] 本次等待的不可变快照。
    def expect(*patterns, from: [], timeout: configuration.timeout, deadline: nil, &)
      run_expect(from, patterns, timeout, deadline:, &)
    end

    # 返回继续等待的控制符，reset_timeout 决定是否重新计算匹配期限。
    # @return [Symbol] 重置期限或保持期限的继续控制符。
    def continue(reset_timeout: true) = reset_timeout ? CONTINUE : CONTINUE_WITHOUT_RESET

    # 读取不受系统时间调整影响的单调时钟，所有相对超时共用此计时基准。
    # @return [Float] 当前单调时钟秒数。
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # 将秒数转换为有限的非负数，nil 表示无限；供配置和单次操作共用校验。
    # @param value [Numeric, String, nil] 可转换为有限非负秒数的值。
    # @return [Float, nil] 校验后的秒数。
    def duration(value)
      return nil if value.nil?

      number = Float(value)
      raise ArgumentError, "duration must be finite and nonnegative" unless number.finite? && number >= 0

      number
    end

    # 等待并返回可读会话，不消费输入；去重并忽略已关闭会话，默认非阻塞。
    # @param sessions [Array<Expect>] 待读取来源。
    # @return [Array<Expect>] 就绪来源，保持声明顺序。
    def readable_sessions(*sessions, timeout: 0)
      timeout = duration(timeout)
      raise ArgumentError, "readable_sessions requires Expect sessions" unless sessions.all?(Expect)

      active = sessions.uniq(&:object_id).reject(&:closed?)
      return [] if active.empty?

      deadline = timeout && (monotonic + timeout)
      polled = false
      ready = nil
      loop do
        remaining = deadline && [deadline - monotonic, 0].max
        return [] if polled && remaining&.zero?

        begin
          ready = IO.select(active.map(&:to_io), nil, nil, remaining)
          break
        rescue Errno::EINTR
          polled = true
        end
      end
      return [] unless ready

      select_ready_sessions(active, ready.first)
    end

    private

    # 就绪描述符按对象身份归属会话，不能由 IO 子类的值相等规则替代。
    def select_ready_sessions(sessions, readable)
      by_io = readable.each_with_object({}.compare_by_identity) { |io, index| index[io] = true }
      sessions.select { |session| by_io.key?(session.to_io) }
    end

    # 先完成模式声明再启动引擎；无参数块支持简洁 DSL，有参数块保留调用方 self。
    def run_expect(sessions, patterns, timeout, deadline: nil, &block)
      timeout = duration(timeout)
      deadline = Float(deadline) unless deadline.nil?
      raise ArgumentError, "deadline must be finite" if deadline && !deadline.finite?
      raise ArgumentError, "provide patterns or a pattern block, not both" if block_given? && !patterns.empty?

      pattern_list = PatternList.new(sessions, patterns)
      if block
        block.parameters.empty? ? pattern_list.instance_exec(&block) : block.call(pattern_list)
      end
      Matcher.new(pattern_list, timeout, deadline:).run
    end
  end

  extend Forwardable

  # @!method <<(object)
  #   执行操作并返回当前用户会话，支持链式使用。
  #   @return [Expect]
  # @!method after
  #   读取最近结果中的字节快照；尚无结果时为 nil。
  #   @return [String, nil]
  # @!method alive?
  #   查询当前会话状态；输入结束、进程退出和关闭分别记录。
  #   @return [Boolean]
  # @!method before
  #   读取最近结果中的字节快照；尚无结果时为 nil。
  #   @return [String, nil]
  # @!method buffer
  #   取得接收字节；buffer 返回副本，clear_buffer 移交并清空现有内容。
  #   @return [String]
  # @!method buffer=(value)
  #   校验并替换当前设置；缓冲和集合采用副本，IO 与回调只借用。
  #   @return [void]
  # @!method buffer_discarded_bytes
  #   读取因匹配窗口上限裁剪而丢弃的累计字节数。
  #   @return [Integer]
  # @!method buffer_limit
  #   读取会话独立配置；更改类级默认值不会追溯影响已建立会话。
  #   @return [Integer, nil]
  # @!method buffer_limit=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method captures
  #   读取最近捕获组；未参与的组为 nil，尚无结果时为空数组。
  #   @return [Array<String, nil>]
  # @!method clear_buffer
  #   取得接收字节；buffer 返回副本，clear_buffer 移交并清空现有内容。
  #   @return [String]
  # @!method close(graceful: graceful_close?)
  #   关闭所属资源并回收子进程；graceful 启用先收尾输出，硬关闭始终兜底。
  #   @return [nil]
  # @!method closed?
  #   查询当前会话状态；输入结束、进程退出和关闭分别记录。
  #   @return [Boolean]
  # @!method command
  #   读取已启动命令的冻结参数快照，未启动时为 nil。
  #   @return [Array<String>, nil]
  # @!method debug_level
  #   读取会话独立配置；更改类级默认值不会追溯影响已建立会话。
  #   @return [Integer]
  # @!method debug_level=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method diagnostic_output
  #   读取借用的诊断目标；nil 使用 stderr。
  #   @return [#info, #write, Proc, nil]
  # @!method diagnostic_output=(value)
  #   校验并替换当前设置；缓冲和集合采用副本，IO 与回调只借用。
  #   @return [void]
  # @!method eof?
  #   查询当前会话状态；输入结束、进程退出和关闭分别记录。
  #   @return [Boolean]
  # @!method error
  #   读取最近 EOF、超时或原始 IO 错误，匹配成功时为 nil。
  #   @return [Symbol, Exception, nil]
  # @!method exit_code
  #   读取对应进程、IO 或匹配属性；尚无可用值时为 nil。
  #   @return [Integer, nil]
  # @!method fileno
  #   读取对应进程、IO 或匹配属性；尚无可用值时为 nil。
  #   @return [Integer, nil]
  # @!method graceful_close=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method graceful_close?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method hard_close(timeout: 0.2)
  #   等待或回收子进程，未取得真实状态时返回 nil；期限以秒计。
  #   @return [Process::Status, nil]
  # @!method interact(input: $stdin, escape: nil, output: nil, timeout: nil)
  #   临时转接输入和输出，退出时恢复终端与监听设置；超时返回 nil。
  #   @return [Expect, nil]
  # @!method last_result
  #   读取最近一次等待的不可变结果。
  #   @return [Expect::Result, nil]
  # @!method listeners
  #   读取监听目标数组的副本；监听器只借用，不随会话关闭。
  #   @return [Array<#write>]
  # @!method listeners=(value)
  #   校验并替换当前设置；缓冲和集合采用副本，IO 与回调只借用。
  #   @return [void]
  # @!method log_listeners=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method log_listeners?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method log_output
  #   读取当前接收日志目标，不包含发送数据。
  #   @return [#write, Proc, nil]
  # @!method log_output=(value)
  #   校验并替换当前设置；缓冲和集合采用副本，IO 与回调只借用。
  #   @return [void]
  # @!method log_stdout=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method log_stdout?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method log_to(target = nil, mode: "a", &block)
  #   设置借用日志目标或打开所属日志文件；返回目标。
  #   @return [#write, Proc]
  #   @yieldparam bytes [String] 实际读取的字节。
  #   @yieldreturn [Object] 回调返回值不影响匹配。
  # @!method match
  #   读取最近结果中的字节快照；尚无结果时为 nil。
  #   @return [String, nil]
  # @!method match_number
  #   读取对应进程、IO 或匹配属性；尚无可用值时为 nil。
  #   @return [Integer, nil]
  # @!method on_sequence(sequence, &block)
  #   执行操作并返回当前用户会话，支持链式使用。
  #   @return [Expect]
  #   @yield 转义匹配完成后运行，nil/false 停止，其余返回值继续。
  #   @yieldreturn [Object] 是否继续转接。
  # @!method pending_output?
  #   查询当前会话状态；输入结束、进程退出和关闭分别记录。
  #   @return [Boolean]
  # @!method pid
  #   读取对应进程、IO 或匹配属性；尚无可用值时为 nil。
  #   @return [Integer, nil]
  # @!method preserve_buffer=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method preserve_buffer?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method process_status
  #   非阻塞回收直属子进程并读取真实状态；未知时保留 nil。
  #   @return [Process::Status, nil]
  # @!method puts(*objects)
  #   按 Ruby puts 语义转换换行、nil 和数组后写入。
  #   @return [nil]
  # @!method raw_pty=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method raw_pty?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method raw_terminal=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method raw_terminal?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method redact(*secrets)
  #   执行操作并返回当前用户会话，支持链式使用。
  #   @return [Expect]
  # @!method reset_timeout_on_read=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method reset_timeout_on_read?
  #   按 Ruby 真值规则查询此布尔配置。
  #   @return [Boolean]
  # @!method send_slow(*objects, delay:)
  #   返回已写字节数；背压超时抛出 WriteTimeout 并保留 bytes_written。
  #   @return [Integer]
  # @!method slave
  #   读取 PTY slave；适配已有 IO 时为 nil，启动后句柄已关闭。
  #   @return [IO, nil]
  # @!method soft_close(timeout: 15, term_timeout: 1)
  #   等待或回收子进程，未取得真实状态时返回 nil；期限以秒计。
  #   @return [Process::Status, nil]
  # @!method spawn(*command, env: {}, chdir: nil)
  #   执行操作并返回当前用户会话，支持链式使用。
  #   @return [Expect]
  # @!method stty(*modes)
  #   查询或设置终端模式；非 TTY 返回空字符串，失败抛出 IO 错误。
  #   @return [String]
  # @!method timeout
  #   读取会话独立配置；更改类级默认值不会追溯影响已建立会话。
  #   @return [Numeric, nil]
  # @!method timeout=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method to_io
  #   取得底层读端或写端，不复制描述符。
  #   @return [IO]
  # @!method tty?
  #   查询当前会话状态；输入结束、进程退出和关闭分别记录。
  #   @return [Boolean]
  # @!method tty_name
  #   读取 PTY 终端路径；适配已有 IO 时为 nil。
  #   @return [String, nil]
  # @!method wait(timeout: nil)
  #   等待或回收子进程，未取得真实状态时返回 nil；期限以秒计。
  #   @return [Process::Status, nil]
  # @!method winsize
  #   读取终端行列数，保留原生 IO 错误。
  #   @return [Array<Integer>]
  # @!method winsize=(value)
  #   校验并替换当前设置；缓冲和集合采用副本，IO 与回调只借用。
  #   @return [void]
  # @!method write(*objects)
  #   返回已写字节数；背压超时抛出 WriteTimeout 并保留 bytes_written。
  #   @return [Integer]
  # @!method write_log(*objects)
  #   向当前接收日志补写数据；返回目标调用结果，过滤暂存时可为 nil。
  #   @return [Object]
  # @!method write_timeout
  #   读取会话独立配置；更改类级默认值不会追溯影响已建立会话。
  #   @return [Numeric, nil]
  # @!method write_timeout=(value)
  #   校验并设置会话配置；非法数值不改变当前值，布尔值遵循 Ruby 真值。
  #   @return [void]
  # @!method writer
  #   取得底层读端或写端，不复制描述符。
  #   @return [IO]
  # @!method inspect
  #   返回不含缓冲、命令或秘密内容的安全诊断摘要。
  #   @return [String]
  # 用户会话只委托稳定接口，内核读写、转接标记和资源账本不出现在公开方法中。
  def_delegators :@session,
                 :<<, :after, :alive?, :before, :buffer, :buffer=, :buffer_discarded_bytes, :buffer_limit,
                 :buffer_limit=, :captures, :clear_buffer, :close, :closed?, :command, :debug_level,
                 :debug_level=, :diagnostic_output, :diagnostic_output=, :eof?, :error, :exit_code, :fileno,
                 :graceful_close=, :graceful_close?, :hard_close, :interact, :last_result,
                 :listeners, :listeners=, :log_listeners=, :log_listeners?, :log_output,
                 :log_output=, :log_stdout=, :log_stdout?, :log_to, :match, :match_number,
                 :on_sequence, :pending_output?, :pid, :preserve_buffer=, :preserve_buffer?,
                 :process_status, :puts, :raw_pty=, :raw_pty?, :raw_terminal=,
                 :raw_terminal?, :redact, :reset_timeout_on_read=,
                 :reset_timeout_on_read?, :send_slow, :slave, :soft_close, :spawn, :stty, :timeout, :timeout=,
                 :to_io, :tty?, :tty_name, :wait, :winsize, :winsize=, :write, :write_log, :write_timeout,
                 :write_timeout=, :writer, :inspect

  # 创建 PTY，可立即执行命令；未完成初始化时按局部所有权释放全部句柄。
  # @param command [Array<String>] 可选启动命令及参数。
  # @return [Expect] 已创建的用户会话。
  def initialize(*command, env: {}, chdir: nil, **)
    master = slave = nil
    Cleanup.on_failure(-> { cleanup_session(master, writer: master, slave:, own: true) }) do
      master, slave = PTY.open
      initialize_session(master, writer: master, slave:, own: true, **)
      spawn(*command, env:, chdir:) unless command.empty?
    end
  end

  # 返回不可变结果；模式块无参数时使用 DSL，有参数时保留调用者 self。
  # @param patterns [Array<String, Regexp, Symbol>] 文本模式、:eof 或 :timeout。
  # @param timeout [Numeric, nil] 相对秒数，nil 无限，0 非阻塞轮询。
  # @param deadline [Numeric, nil] 单调时钟绝对期限，不被回调延长。
  # @yieldparam patterns [Expect::PatternList] 有参数块接收构建器；无参数块以 DSL 执行。
  # @return [Expect::Result] 本次等待的不可变快照。
  def expect(*patterns, timeout: self.timeout, deadline: nil, &)
    self.class.__send__(:run_expect, [self], patterns, timeout, deadline:, &)
  end

  # 返回回调继续控制符，可选择保持原期限。
  # @return [Symbol] 重置期限或保持期限的继续控制符。
  def continue(reset_timeout: true) = Expect.continue(reset_timeout:)

  private

  attr_reader :session

  def initialize_session(reader, **)
    @session = Session.allocate
    @session.initialize_connection(self, reader, **)
  end

  def cleanup_session(reader, writer:, own:, slave: nil, graceful: false)
    if @session
      @session.cleanup_session(reader, writer:, own:, slave:, graceful:)
    elsif own
      SessionResources.close_handles(reader, writer, slave)
    end
  end
end
