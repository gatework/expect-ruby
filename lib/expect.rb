# frozen_string_literal: true

require "pty"
require "io/console"
require "io/wait"
require "stringio"
require "forwardable"
require_relative "expect/version"
require_relative "expect/configuration"
require_relative "expect/result"
require_relative "expect/session_resources"
require_relative "expect/pattern"
require_relative "expect/pattern_list"
require_relative "expect/matcher"

# 自动化交互会话：可以拥有一个 PTY 子进程，也可以适配已有可 select 的 IO。
# 缓冲和匹配统一保留原始字节，配置、匹配结果与资源生命周期分别管理。
class Expect
  # 回调控制符：分别表示重置期限后继续，或保留原期限继续。
  CONTINUE = :continue
  CONTINUE_WITHOUT_RESET = :continue_without_reset
  READ_SIZE = 16_384
  CONFIGURATION_MUTEX = Mutex.new
  private_constant :CONFIGURATION_MUTEX

  class SpawnError < StandardError; end
  class ReentrancyError < StandardError; end

  # 已被底层接受的字节不可撤回；调用方可据此只处理尚未写出的后缀。
  class WriteTimeout < IOError
    attr_reader :bytes_written

    def initialize(message = "write timed out", bytes_written: 0)
      @bytes_written = bytes_written
      super(message)
    end
  end

  class << self
    # 读取冻结的默认配置；子类未单独配置时继承父类快照。
    def configuration
      return @configuration if defined?(@configuration)
      return superclass.configuration unless self == Expect

      CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new.freeze }
    end

    # 基于旧快照构造可修改副本，全部赋值与配置块成功后才发布，异常时保留原配置。
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
    def spawn(*command, env: {}, chdir: nil, **)
      session = new(**)
      session.spawn(*command, env: env, chdir: chdir)
      spawned = true
      return session unless block_given?

      yield session
    rescue Exception # rubocop:disable Lint/RescueException -- 记录本次作用域的失败，清理后原样传播，包括非 StandardError 异常。
      failed = true
      raise
    ensure
      if session && (block_given? || !spawned)
        session.__send__(:cleanup, failed: failed) do
          session.close(graceful: spawned && session.graceful_close?)
        end
      end
    end

    # 适配已有 IO；own: true 接管关闭责任，初始化失败也释放接管的读写端。
    def open(io, writer: io, own: false, **)
      session = allocate
      session.__send__(:initialize_session, io, writer: writer, own: own, **)
      initialized = true
      return session unless block_given?

      yield session
    rescue Exception # rubocop:disable Lint/RescueException -- 初始化和块异常均须保留，清理失败不能替换原始原因。
      failed = true
      raise
    ensure
      if session && (block_given? || !initialized)
        session.__send__(:cleanup, failed: failed) do
          session.__send__(:cleanup_session, io, writer: writer, own: own,
                                                 graceful: initialized && session.graceful_close?)
        end
      end
    end

    # 进行多会话匹配，返回命中的模式序号，超时、EOF 或读取错误返回 nil。
    def expect(...) = expect_result(...).number

    # 多会话等待的完整结果入口；from: 提供默认来源，块内可分别指定每个模式的来源。
    def expect_result(*patterns, from: [], timeout: configuration.timeout, deadline: nil, &)
      run_expect(from, patterns, timeout, deadline: deadline, &)
    end

    # 返回继续等待的控制符，reset_timeout 决定是否重新计算匹配期限。
    def continue(reset_timeout: true) = reset_timeout ? CONTINUE : CONTINUE_WITHOUT_RESET

    # 读取不受系统时间调整影响的单调时钟，所有相对超时共用此计时基准。
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # 将秒数转换为有限的非负数，nil 表示无限；供配置和单次操作共用校验。
    def duration(value)
      return nil if value.nil?

      number = Float(value)
      raise ArgumentError, "duration must be finite and nonnegative" unless number.finite? && number >= 0

      number
    end

    # 等待并返回可读会话，不消费输入；去重并忽略已关闭会话，默认非阻塞。
    def readable_sessions(*sessions, timeout: 0)
      timeout = duration(timeout)
      raise ArgumentError, "readable_sessions requires Expect sessions" unless sessions.all?(Expect)

      active = sessions.uniq.reject(&:closed?)
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

      active.select { |session| ready.first.include?(session.to_io) }
    end

    private

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
      Matcher.new(pattern_list.validate!, timeout, deadline: deadline).run
    end
  end

  extend Forwardable

  # 普通属性委托给会话独立配置；缓冲上限的 setter 还需立即裁剪现有缓冲。
  def_delegators :@configuration, *Configuration::ATTRIBUTES, *Configuration::PREDICATES
  def_delegators :@configuration, *(Configuration::ATTRIBUTES - [:buffer_limit]).map { |name| :"#{name}=" }

  attr_reader :command, :last_result, :slave, :tty_name, :buffer_discarded_bytes

  # 校验并更新缓冲上限后，立即裁剪已接收的内容；校验失败不改变旧缓冲。
  def buffer_limit=(value)
    @configuration.buffer_limit = value
    trim_buffer
    value
  end

  # 创建 PTY，可立即启动命令，也可先让调用方配置 slave；构造失败时释放全部新句柄。
  def initialize(*command, env: {}, chdir: nil, **)
    master, slave = PTY.open
    initialize_session(master, writer: master, slave: slave, own: true, **)
    @tty_name = slave.path
    spawn(*command, env: env, chdir: chdir) unless command.empty?
    initialized = true
  rescue Exception # rubocop:disable Lint/RescueException -- 构造异常时也要关闭已创建的资源并回收已启动的子进程。
    failed = true
    raise
  ensure
    cleanup(failed:) { cleanup_session(master, writer: master, slave: slave, own: true) } unless initialized
  end

  # 在新控制终端中执行命令并同步确认 exec 结果；同一会话只能启动一次。
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- PTY 子进程启动与失败回传共用一次生命周期。
  def spawn(*command, env: {}, chdir: nil)
    raise SpawnError, "cannot reuse a spawned session" if @command
    raise SpawnError, "only a new PTY session can spawn" unless @slave && !@slave.closed? && !closed?
    raise ArgumentError, "command is required" if command.empty?
    raise ArgumentError, "command arguments must be strings" unless command.all? do |part|
      part.is_a?(String) && !part.include?("\0")
    end
    raise ArgumentError, "command is empty" if command.first.empty?

    @slave.raw! if raw_pty?
    # 错误管道的写端在 exec 成功时自动关闭；父进程据此区分成功启动与 exec 前失败。
    from_child, to_parent = IO.pipe
    to_parent.close_on_exec = true
    @command = command.map { |part| part.dup.freeze }.freeze
    child = fork do
      from_child.close
      Process.setsid
      # 创建独立进程会话后重新打开 slave，使它成为子进程的控制终端。
      File.open(@tty_name, File::RDWR) do |terminal|
        # 重定向操作系统的标准描述符；即使宿主替换过 Ruby 标准流，也能正确连接子进程。
        # rubocop:disable Style/GlobalStdStream
        STDIN.reopen(terminal)
        STDOUT.reopen(terminal)
        STDERR.reopen(terminal)
        # rubocop:enable Style/GlobalStdStream
      end
      @resources.close_handles
      Dir.chdir(chdir) if chdir
      exec(env, *command, close_others: true)
    rescue Exception => error # rubocop:disable Lint/RescueException -- 子进程回传启动异常后立即退出。
      begin
        to_parent.write("#{error.class}: #{error.message}")
      ensure
        exit! 127
      end
    end
    @resources.pid = child
    to_parent.close
    @slave.close
    failure = from_child.read
    unless failure.empty?
      hard_close
      raise SpawnError, failure
    end
    trace("spawned pid=#{child}", event: :spawned)
    self
  ensure
    from_child&.close unless from_child&.closed?
    to_parent&.close unless to_parent&.closed?
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # 在当前会话等待文本或事件，返回模式序号或 nil。
  def expect(...) = expect_result(...).number

  # 使用会话默认超时构造一次等待，返回含匹配内容、来源和错误的 Result。
  def expect_result(*patterns, timeout: self.timeout, deadline: nil, &)
    self.class.__send__(:run_expect, [self], patterns, timeout, deadline: deadline, &)
  end

  # 供实例回调返回继续控制符，语义与 Expect.continue 相同。
  def continue(reset_timeout: true) = Expect.continue(reset_timeout: reset_timeout)

  # 暴露底层读写 IO 与终端属性，供 select、终端设置及 IO 适配使用。
  def to_io = @resources.reader

  def writer = @resources.writer

  def fileno = closed? ? nil : to_io.fileno

  def tty? = !closed? && to_io.tty?

  # 诊断时仅显示进程和描述符状态，避免默认对象展开泄露缓冲或日志内容。
  def inspect = "#<#{self.class} pid=#{pid.inspect} fd=#{fileno.inspect} closed=#{closed?}>"

  def pid = @resources.pid

  # 非阻塞回收并缓存子进程状态；未退出或仅适配 IO 时返回 nil。
  def process_status
    @resources.reap
  rescue Errno::EINTR
    # 单次轮询被中断时状态仍未知；wait/close 会在原期限内继续，不在这里无限重试。
    @resources.status
  end

  def exit_code = process_status&.exitstatus

  # 先刷新回收状态，再判断是否仍有未回收的子进程；不以 IO 是否关闭代替进程状态。
  def alive?
    process_status
    !pid.nil?
  end

  # 区分会话关闭和输入结束，已关闭会话也不能继续读取。
  def closed? = @closed || to_io.closed?

  def eof? = @eof || closed?

  # 以下访问器读取最近一次等待结果；未发生匹配时捕获组返回空数组。
  def before = @last_result&.before

  def after = @last_result&.after

  def match = @last_result&.match

  def match_number = @last_result&.number

  def captures = @last_result&.captures || []

  def error = @last_result&.error

  # 返回缓冲副本，防止调用方原地修改绕过裁剪规则。
  def buffer = @buffer.dup

  # 复制并替换原始字节缓冲，应用当前上限；调用方后续修改原字符串不会影响会话。
  def buffer=(value)
    raise ArgumentError, "buffer must be a String" unless value.is_a?(String)

    @buffer = value.b
    @buffer_generation += 1
    trim_buffer
  end

  # 移交旧缓冲并换上新的空字节串，供显式清空或人工转接接管数据。
  def clear_buffer
    previous = @buffer
    @buffer = "".b
    @buffer_generation += 1
    previous
  end

  # 按 Ruby to_s 规则原样写入所有字节，返回字节数；背压等待受 write_timeout 限制。
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 写入、背压排空和同一期限必须同步推进。
  def write(*objects)
    raise IOError, "closed Expect session" if closed? || writer.closed?

    data = objects.map { |object| object.to_s.b }.join
    trace_data(:sending, data, level: 2) if debug_level >= 2
    deadline = write_timeout && (Expect.monotonic + write_timeout)
    offset = 0
    while offset < data.bytesize
      begin
        chunk = data.byteslice(offset, READ_SIZE)
        count = writer.write_nonblock(chunk, exception: false)
      rescue Errno::EINTR
        raise WriteTimeout.new(bytes_written: offset) if deadline && Expect.monotonic >= deadline

        next
      end
      if count == :wait_writable
        raise WriteTimeout.new(bytes_written: offset) if deadline && Expect.monotonic >= deadline

        remaining = deadline && [deadline - Expect.monotonic, 0].max
        # 子进程也可能因输出管道填满而停止读取；等可写时同时排空它的输出，避免双向死锁。
        readers = eof? ? [] : [to_io]
        begin
          ready = IO.select(readers, [writer], nil, remaining)
          raise WriteTimeout.new(bytes_written: offset) unless ready

          if ready[0].include?(to_io)
            begin
              read_available
            rescue WriteTimeout
              # 日志或监听器可嵌套写入；对外报告本次写入进度，原异常通过 cause 保留。
              raise WriteTimeout.new("write interrupted by an output timeout", bytes_written: offset)
            end
          end
        rescue Errno::EINTR
          next
        end
      else
        unless count.is_a?(Integer) && count.positive? && count <= chunk.bytesize
          raise IOError, "write must return the number of accepted bytes"
        end

        offset += count
      end
    end
    data.bytesize
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # 链式写入单个对象，返回当前会话。
  def <<(object)
    write(object)
    self
  end

  # 委托 StringIO 处理换行、nil 和递归数组，再统一写入；返回 nil，与 Ruby puts 一致。
  def puts(*objects)
    output = StringIO.new("".b)
    output.puts(*objects)
    write(output.string)
    nil
  end

  # 逐字符延迟发送，同时收集回复，适配输入处理较慢的交互程序；返回写入字节数。
  def send_slow(*objects, delay:)
    pause = Expect.duration(delay)
    raise ArgumentError, "delay is required" unless pause

    count = 0
    objects.each do |object|
      object.to_s.each_char do |character|
        sleep(pause) if pause.positive?
        count += write(character)
        read_available if !eof? && to_io.wait_readable(0)
      end
    end
    count
  end

  # 轮询回收状态直到进程退出或期限到达；返回 Process::Status 或 nil，超时不丢弃 PID。
  def wait(timeout: nil)
    wait_for_child(Expect.duration(timeout))
  end

  # 先在自然退出期限内收集尾部输出，再关闭句柄并最多发送 TERM；不会发送 KILL。
  # 尚未退出时返回 nil 并保留 PID，调用方可以继续等待或随后硬关闭。
  def soft_close(timeout: 15, term_timeout: 1)
    period = Expect.duration(timeout)
    term_timeout = Expect.duration(term_timeout)
    raise ArgumentError, "term_timeout must be finite" unless term_timeout

    deadline = period && (Expect.monotonic + period)
    until eof?
      remaining = deadline && [deadline - Expect.monotonic, 0].max
      break if remaining&.zero? || !to_io.wait_readable(remaining)

      read_available
    end
    close_resources(timeout: deadline ? [deadline - Expect.monotonic, 0].max : nil,
                    term_timeout: term_timeout, force: false)
  end

  # 立即关闭句柄，再分阶段等待、TERM、KILL；不收集剩余输出，返回已回收状态或 nil。
  def hard_close(timeout: 0.2)
    period = Expect.duration(timeout)
    raise ArgumentError, "hard_close timeout must be finite" unless period

    close_resources(timeout: period, term_timeout: period, force: true)
  end

  # 通用生命周期清理：可先软关闭，ensure 中硬关闭兜底；正常完成返回 nil。
  def close(graceful: graceful_close?)
    soft_close if graceful
    nil
  rescue Exception # rubocop:disable Lint/RescueException -- 软关闭的原始异常在硬关闭兜底后继续传播。
    failed = true
    raise
  ensure
    cleanup(failed:) { hard_close }
  end

  private

  # 账本发布前只按局部所有权清理；发布后沿用完整关闭流程，避免两套生命周期状态。
  def cleanup_session(reader, writer:, own:, slave: nil, graceful: false)
    if @resources
      close(graceful: graceful)
    elsif own
      SessionResources.close_handles(reader, writer, slave)
    end
  end

  # 仅在本次生命周期已有异常时抑制常规清理错误；调用者 rescue 中的旧异常不算本次失败。
  def cleanup(failed:)
    yield
  rescue IOError, SystemCallError
    raise unless failed
  end

  # 共用的进程关闭流程；force 控制是否允许 KILL，只有资源创建者能够操作直属子进程。
  def close_resources(timeout:, term_timeout:, force:)
    failure = nil
    # 预期的清理错误延后传播，保证其余所属资源和直属子进程仍能完成清理。
    cleanup = lambda do |&step|
      step.call
    rescue IOError, SystemCallError => error
      failure ||= error
      nil
    end
    # IO 关闭与进程退出独立记录：软关闭可能已经 closed?，但仍保留活跃 PID。
    cleanup.call { @resources.close_handles }
    @closed = true
    @interact_inputs&.delete_if do |_io, input|
      cleanup.call do
        input.close(graceful: false)
        true
      end
    end
    @interact_output = nil
    @relay_outputs&.clear
    @relay_history&.clear
    @relay_callback = nil
    status = close_child(timeout: timeout, term_timeout: term_timeout, force: force)
    completed = true
    status
  ensure
    begin
      cleanup.call { flush_diagnostics }
    ensure
      cleanup.call { self.log_output = nil }
    end
    # 用本次流程的完成状态判断异常传播，不能误把调用者 rescue 中的异常当成当前错误。
    raise failure if failure && completed
  end

  # 句柄清理失败不改变进程策略；未回收 PID 保留给重复关闭或终结器继续处理。
  def close_child(timeout:, term_timeout:, force:)
    return process_status unless @resources.owner == Process.pid && pid

    status = wait(timeout: timeout)
    return status if status || !pid

    status = wait_for_child(term_timeout, signal: "TERM")
    return status if status || !pid
    return unless force

    wait_for_child(1, signal: "KILL")
  end

  # 每阶段只计算一次期限；回收或信号被中断后仍沿用剩余预算，零预算也先做一次尝试。
  def wait_for_child(period, signal: nil)
    deadline = period && (Expect.monotonic + period)
    loop do
      status = process_status
      return status if status || !pid || @resources.owner != Process.pid

      begin
        signal_child(signal) if signal
        signal = nil
      rescue Errno::EINTR
        # 下轮先回收再重试信号，避免在无限等待或持续中断时忙等。
        nil
      end
      # ESRCH 后可能已完成回收；即使预算耗尽，也要返回刚获得的状态。
      return process_status unless pid

      remaining = deadline && (deadline - Expect.monotonic)
      return nil if remaining && remaining <= 0

      sleep(remaining ? [0.01, remaining].min : 0.01)
    end
  end

  # 统一初始化 PTY 与已有 IO 会话，复制配置并注册不直接捕获会话的资源终结器。
  def initialize_session(reader, writer:, slave: nil, own: false, diagnostic_output: nil, **)
    # 先登记所有权，后续校验失败也使用同一个资源对象逐个清理所属 IO。
    @resources = SessionResources.new(reader, writer: writer, slave: slave, own: own)
    raise ArgumentError, "reader must be a real IO" unless reader.is_a?(IO) && !reader.closed?
    raise ArgumentError, "writer must be a real IO" unless writer.is_a?(IO) && !writer.closed?

    @pty = reader.tty?
    @slave = slave
    @configuration = Configuration.new(**self.class.configuration.to_h, **)
    @buffer = "".b
    @buffer_generation = 0
    @buffer_discarded_bytes = 0
    @listeners = []
    @sequences = {}
    @relay_outputs = []
    @closed = @eof = false
    self.diagnostic_output = diagnostic_output
    ObjectSpace.define_finalizer(self, SessionResources.finalizer(@resources))
  end

  # 开始新一轮等待时清除旧结果并应用缓冲上限，尚未消费的输入继续保留。
  def reset_result
    @last_result = nil
    trim_buffer
  end

  # 按字节偏移生成 before/match/after；通常只保留 after，preserve_buffer 开启时不消费。
  def record_match(pattern, position)
    offset, length, captures = position
    @last_result = Result.new(number: pattern.number, before: @buffer.byteslice(0, offset),
                              match: @buffer.byteslice(offset, length), after: @buffer.byteslice((offset + length)..),
                              session: self, captures: captures)
    unless preserve_buffer?
      @buffer = @last_result.after.dup
      @buffer_generation += 1
    end
    # 诊断回调可能嵌套等待；恢复本次结果后再交给正式模式回调，不能返回内层等待的结果。
    result = @last_result
    trace("matched pattern #{pattern.number}")
    @last_result = result
  end

  # 记录超时、EOF 或原始 IO 异常，保留当前缓冲快照并清除旧匹配及捕获组。
  def record_error(error)
    @last_result = Result.new(error: error, before: buffer, session: self, captures: [])
  end

  # 输入结束时将剩余缓冲放入 before 并清空，尝试回收但不终止仍活跃的子进程。
  def record_eof
    process_status
    record_error(:eof)
    clear_buffer
    @last_result
  end

  # 先将读取字节交给匹配或转接缓冲，再记录日志；日志失败也能恢复输入。
  def read_available(propagate: true, buffer: @buffer, trim: true)
    return nil if eof?

    # 写入背压也会读取；转接期间统一交给转义处理器，不能直接转发或另存匹配缓冲。
    if @interaction_buffer
      buffer = @interaction_buffer
      propagate = false
      trim = false
    end

    begin
      data = to_io.read_nonblock(READ_SIZE, exception: false)
    rescue Errno::EIO
      # 某些系统用 PTY 的 EIO 表示对端关闭；普通 IO 的同类错误仍按异常处理。
      raise unless @pty

      return mark_eof
    rescue EOFError
      return mark_eof
    end
    return nil if data == :wait_readable

    return mark_eof if data.nil?

    data = data.b
    buffer << data
    trim_buffer if trim
    trace_data(:received, data, level: 2) if debug_level >= 2
    trace_data(:buffer, @buffer, level: 3) if debug_level >= 3
    # 仅在真实读取时记录日志，后续匹配或人工转接重用缓冲时不会重复记录。
    write_log(data)
    propagate(data) if propagate
    data
  end

  def mark_eof
    @eof = true
    flush_log
    flush_diagnostics(:received)
    nil
  end

  # 缓冲超过上限时只保留最新尾部字节，不对编码做隐式修改。
  def trim_buffer
    limit = buffer_limit
    return unless limit && @buffer.bytesize > limit

    # 只累计匹配窗口裁剪，消费、清空及转接交接不算丢弃；关闭后仍可读取累计值。
    @buffer_discarded_bytes += @buffer.bytesize - limit
    @buffer = @buffer.byteslice(-limit, limit)
    @buffer_generation += 1
  end

  # 仅由资源创建者向仍未回收的子进程发送信号；若进程刚好退出，则尝试回收。
  def signal_child(signal)
    return unless pid && @resources.owner == Process.pid

    Process.kill(signal, pid)
  rescue Errno::ESRCH
    @resources.reap
  end
end

require_relative "expect/logging"
require_relative "expect/terminal"
require_relative "expect/interaction"
