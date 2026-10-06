# frozen_string_literal: true

require_relative "logging"
require_relative "interaction"

module Expect
  # 一个真实 PTY 或 IO 会话；缓冲、最近结果和所属进程都保存在本对象中。
  # SessionResources 保存可独立回收的资源账本；Matcher、Relay 仅在操作期间借用会话状态。
  # 日志与协议目标属于调用方，显式关闭和 GC 均不得接管这些借用对象。
  class Session
    include Logging
    include Interaction

    # 启动命令、最近结果及 PTY 端点的只读状态；文本结果属于不可变快照。
    attr_reader :command, :last_result, :slave, :tty_name, :buffer_discarded_bytes
    # 会话的默认等待期限、写入背压期限及缓冲上限。
    attr_reader :timeout, :write_timeout, :buffer_limit

    # 预建 PTY；命令、env、chdir 与 raw 模式由 spawn 显式设置。
    def initialize(timeout: nil, write_timeout: nil, buffer_limit: nil, logger: nil, transcript: nil, outputs: [])
      master = slave = nil
      Cleanup.on_failure(-> { cleanup_session(master, writer: master, slave:, own: true) }) do
        master, slave = PTY.open
        initialize_io(master, writer: master, slave:, own: true, timeout:, write_timeout:, buffer_limit:,
                              logger:, transcript:, outputs:)
      end
    end

    # 设置本会话后续 expect 默认使用的相对秒数，nil 表示无限等待。
    def timeout=(value)
      @timeout = Expect.duration(value)
    end

    # 设置写入遇到背压或 EINTR 时的等待秒数；成功短写不受总耗时限制。
    def write_timeout=(value)
      @write_timeout = Expect.duration(value)
    end

    # 校验并更新缓冲上限，立即裁剪现有尾部；非法值不改变配置和内容。
    def buffer_limit=(value)
      unless value.nil? || (value.is_a?(Integer) && value.positive?)
        raise ArgumentError, "buffer_limit must be a positive Integer or nil"
      end

      @buffer_limit = value
      trim_buffer
    end

    # 等待自身输入，返回 Result；匹配消费和接收重置策略只对本轮有效。
    def expect(*patterns, timeout: self.timeout, deadline: nil, consume: true, reset_timeout_on_read: false, &)
      Expect.__send__(:run_expect, [self], patterns, timeout, deadline:, consume:, reset_timeout_on_read:, &)
    end

    # 在新控制终端中执行命令并同步确认 exec 结果；同一会话只能启动一次。
    def spawn(*command, env: {}, chdir: nil, raw: false)
      validate_spawn!(command)

      @slave.raw! if raw
      from_child = to_parent = nil
      Cleanup.always(-> { SessionResources.close_handles(from_child, to_parent) }) do
        # 错误管道的写端在 exec 成功时自动关闭；父进程据此区分成功启动与 exec 前失败。
        from_child, to_parent = IO.pipe
        to_parent.close_on_exec = true
        @command = command.map { |part| part.dup.freeze }.freeze
        # 原生 fork 返回后先登记 PID，再交付线程中断或终止，避免清理时遗漏新子进程。
        child = Thread.handle_interrupt(Object => :never) do
          @resources.pid = fork do
            # 子进程不继承父侧登记临界区，执行前仍可立即响应异步异常。
            Thread.handle_interrupt(Object => :immediate) { exec_child(command, env:, chdir:, from_child:, to_parent:) }
          end
        end
        to_parent.close
        @slave.close
        failure = from_child.read
        Cleanup.always(-> { hard_close }) { raise SpawnError, failure } unless failure.empty?
        trace("spawned pid=#{child}", event: :spawned)
        self
      end
    end

    # 暴露底层读写 IO 与终端属性，供 select、终端设置及 IO 适配使用。
    def to_io = @resources.reader

    # 实际写入端点，可能不同于 to_io 返回的读端。
    def writer = @resources.writer

    # 当前读端描述符；会话关闭后为 nil。
    def fileno = closed? ? nil : to_io.fileno

    # 读端仍打开且属于终端时为 true。
    def tty? = !closed? && to_io.tty?

    # 诊断时仅显示进程和描述符状态，避免默认对象展开泄露缓冲或日志内容。
    def inspect = "#<#{self.class} pid=#{pid.inspect} fd=#{fileno.inspect} closed=#{closed?}>"

    # 尚未完成回收的直属子进程 PID；已有 IO 会话为 nil。
    def pid = @resources.pid

    # 非阻塞回收并缓存子进程状态；未退出或仅适配 IO 时返回 nil。
    def process_status
      @resources.reap
    rescue Errno::EINTR
      # 单次轮询被中断时状态仍未知；wait/close 会在原期限内继续，不在这里无限重试。
      @resources.status
    end

    # 已知进程退出码；尚未回收或信号退出时为 nil。
    def exit_code = process_status&.exitstatus

    # 先刷新回收状态，再判断是否仍有未回收的子进程；不以 IO 是否关闭代替进程状态。
    def alive?
      process_status
      !pid.nil?
    end

    # 区分会话关闭和输入结束，已关闭会话也不能继续读取。
    def closed? = @closed || to_io.closed?

    # 输入已结束或会话已关闭时为 true。
    def eof? = @eof || closed?

    # 以下访问器读取最近一次等待结果；未发生匹配时捕获组返回空数组。
    def before = @last_result&.before

    # 最近一次匹配之后的不可变字节快照。
    def after = @last_result&.after

    # 最近一次匹配命中的不可变字节快照。
    def match = @last_result&.match

    # 最近命中的模式序号；EOF、超时或尚无结果时为 nil。
    def match_number = @last_result&.number

    # 最近捕获值的不可变数组；未参与的捕获为 nil。
    def captures = @last_result&.captures || []

    # 最近的 EOF、超时事件或原始 IO 异常。
    def error = @last_result&.error

    # 返回缓冲副本，防止调用方原地修改绕过裁剪规则。
    def buffer = @buffer.dup

    # Matcher 仅在无回调的当前扫描借用原字节，避免副本使下一次追加复制整个窗口。
    # 不得修改或跨读取、回调保留；公开 buffer 和继续回调的快照仍独立复制。
    # @api private
    def scan_buffer = @buffer

    # 复制并替换原始字节缓冲，应用当前上限；调用方后续修改原字符串不会影响会话。
    def buffer=(value)
      raise ArgumentError, "buffer must be a String" unless value.is_a?(String)

      @buffer = value.b
      @buffer_generation += 1
      @relay_history.clear
      trim_buffer
    end

    # 显式清空并返回旧字节；它建立新的输入边界，不能再拼接此前的正则转义历史。
    def clear_buffer
      @relay_history.clear
      take_buffer
    end

    # Matcher / Relay 的所有权交接不消费输入，也不能截断跨次转接的正则历史。
    # @api private
    def take_buffer
      previous = @buffer
      @buffer = "".b
      @buffer_generation += 1
      previous
    end

    # 按 Ruby to_s 规则原样写入所有字节，返回字节数；背压等待受 write_timeout 限制。
    def write(*objects)
      raise IOError, "closed Expect session" if closed? || writer.closed?

      begin
        data = objects.map { |object| object.to_s.b }.join
        trace_data(:sending, data)
      rescue WriteTimeout
        # 转换或诊断中的嵌套写入不属于当前命令；此时尚未向 writer 发送任何字节。
        raise WriteTimeout.new("write interrupted before sending data", bytes_written: 0)
      end
      deadline = write_timeout && (Expect.monotonic + write_timeout)
      offset = 0
      while offset < data.bytesize
        count = write_chunk(data, offset, deadline)
        next unless count

        if count == :wait_writable
          raise WriteTimeout.new(bytes_written: offset) if deadline && Expect.monotonic >= deadline

          wait_writable(offset, deadline)
        else
          offset += count
        end
      end
      data.bytesize
    end

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

    # 逐字符延迟发送，同时收集回复；返回总字节数，背压失败也报告本次累计确认进度。
    def send_slow(*objects, delay:)
      pause = Expect.duration(delay)
      raise ArgumentError, "delay is required" unless pause

      count = 0
      writing = false
      begin
        objects.each do |object|
          object.to_s.each_char do |character|
            sleep(pause) if pause.positive?
            writing = true
            count += write(character)
            writing = false
            read_available if !eof? && to_io.wait_readable(0)
          end
        end
      rescue WriteTimeout => error
        # 只有当前字符的 write 进度属于本次发送；转换和回复交付中的嵌套写入不计入。
        raise if writing && count.zero?

        progress = count + (writing ? error.bytes_written : 0)
        raise WriteTimeout.new("slow send interrupted", bytes_written: progress)
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
                      term_timeout:, force: false)
    end

    # 立即关闭句柄，再分阶段等待、TERM、KILL；不收集剩余输出，返回已回收状态或 nil。
    def hard_close(timeout: 0.2)
      period = Expect.duration(timeout)
      raise ArgumentError, "hard_close timeout must be finite" unless period

      close_resources(timeout: period, term_timeout: period, force: true)
    end

    # 通用生命周期清理：可先软关闭，ensure 中硬关闭兜底；正常完成返回 nil。
    def close(graceful: false)
      Cleanup.always(-> { hard_close }) do
        soft_close if graceful
        nil
      end
    end

    # 账本发布前只按局部所有权清理；发布后沿用完整关闭流程，避免两套生命周期状态。
    # @api private
    def cleanup_session(reader, writer:, own:, slave: nil, graceful: false)
      if @resources
        close(graceful:)
      elsif own
        SessionResources.close_handles(reader, writer, slave)
      end
    end

    # 开始新一轮等待时清除旧结果并应用缓冲上限，尚未消费的输入继续保留。
    # @api private
    def reset_result
      @last_result = nil
      trim_buffer
    end

    # 按字节偏移生成 before/match/after；通常只保留 after，consume 为 false 时不消费。
    # @api private
    def record_match(pattern, position, consume: true)
      offset, length, captures = position
      @last_result = Result.new(number: pattern.number, before: @buffer.byteslice(0, offset),
                                match: @buffer.byteslice(offset, length), after: @buffer.byteslice((offset + length)..),
                                session: self, captures:)
      if consume
        @buffer = @last_result.after.dup
        @buffer_generation += 1
        # before 与 match 都已消费，后续转接不能跨过这段输入拼接旧的转义前缀。
        @relay_history.clear if (offset + length).positive?
      end
      # 诊断回调可能嵌套等待；恢复本次结果后再交给正式模式回调，不能返回内层等待的结果。
      result = @last_result
      trace("matched pattern #{pattern.number}")
      @last_result = result
    end

    # 记录超时、EOF 或原始 IO 异常，保留当前缓冲快照并清除旧匹配及捕获组。
    # @api private
    def record_error(error)
      @last_result = Result.new(error:, before: buffer, session: self, captures: [])
    end

    # 输入结束时将剩余缓冲放入 before 并清空，尝试回收但不终止仍活跃的子进程。
    # @api private
    def record_eof
      process_status
      record_error(:eof)
      clear_buffer
      @last_result
    end

    # 先将读取字节交给匹配或转接缓冲，再记录日志；日志失败也能恢复输入。
    # @api private
    def read_available(propagate: true, buffer: @buffer, trim: true)
      raise ReentrancyError, "cannot read while delivering received data" if @receiving

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
      # 本块完成全部交付前不能递归读取，否则后块会抢先进入其他日志及输出目标。
      # 回调仍可匹配已有缓冲或驱动其他会话；拒绝嵌套读取不能释放外层的保护。
      @receiving = true
      begin
        trace_data(:received, data)
        # 仅在真实读取时记录日志，后续匹配或人工转接重用缓冲时不会重复记录。
        write_transcript(data)
        propagate(data) if propagate
      ensure
        @receiving = false
      end
      data
    end

    private

    # 初始化前先登记所有权；参数校验失败也能释放已取得的端点。
    def initialize_io(reader, writer:, slave: nil, own: false, timeout: nil, write_timeout: nil,
                      buffer_limit: nil, logger: nil, transcript: nil, outputs: [])
      @resources = SessionResources.new(reader, writer:, slave:, own:)
      raise ArgumentError, "reader must be a real IO" unless reader.is_a?(IO) && !reader.closed?
      raise ArgumentError, "writer must be a real IO" unless writer.is_a?(IO) && !writer.closed?

      @pty = reader.tty?
      @slave = slave
      @tty_name = slave.path if slave
      @buffer = "".b
      @buffer_generation = 0
      @buffer_discarded_bytes = 0
      @outputs = []
      @sequences = {}
      @pending_writes = []
      @interact_inputs = {}.compare_by_identity
      @interact_output = nil
      @interaction_buffer = @relay_owner = @relay_callback = nil
      @relay_history = "".b
      @relay_history_sequences = {}
      @secrets = @transcript_redactor = nil
      @diagnostic_redactors = {}
      @logger = @transcript = nil
      @last_result = @command = nil
      @closed = @eof = @receiving = false
      self.timeout = timeout
      self.write_timeout = write_timeout
      self.buffer_limit = buffer_limit
      self.logger = logger
      self.transcript = transcript
      self.outputs = outputs
      ObjectSpace.define_finalizer(self, @resources.method(:finalize))
    end

    # 参数校验先于任何进程和终端修改。
    def validate_spawn!(command)
      raise SpawnError, "cannot reuse a spawned session" if @command
      raise SpawnError, "only a new PTY session can spawn" unless @slave && !@slave.closed? && !closed?
      raise ArgumentError, "command is required" if command.empty?
      raise ArgumentError, "command arguments must be strings" unless command.all? do |part|
        part.is_a?(String) && !part.include?("\0")
      end
      raise ArgumentError, "command is empty" if command.first.empty?
    end

    # 子进程独占控制终端；成功 exec 关闭错误管道，失败时回传后立即退出。
    def exec_child(command, env:, chdir:, from_child:, to_parent:)
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

    # EINTR 未确认交付时不移动游标；其他写入计数必须落在当前块范围内。
    def write_chunk(data, offset, deadline)
      chunk = data.byteslice(offset, READ_SIZE)
      count = writer.write_nonblock(chunk, exception: false)
      return count if count == :wait_writable
      unless count.is_a?(Integer) && count.positive? && count <= chunk.bytesize
        raise IOError, "write must return the number of accepted bytes"
      end

      count
    rescue Errno::EINTR
      raise WriteTimeout.new(bytes_written: offset) if deadline && Expect.monotonic >= deadline

      nil
    end

    # 背压等待同时排空读端，期限不因 EINTR 重算，异常始终报告外层写入进度。
    def wait_writable(offset, deadline)
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
        nil
      end
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
      @pending_writes&.clear
      @relay_history&.clear
      @relay_callback = nil
      status = close_child(timeout:, term_timeout:, force:)
      completed = true
      status
    ensure
      begin
        cleanup.call { flush_diagnostics }
      ensure
        cleanup.call { self.transcript = nil }
      end
      # 用本次流程的完成状态判断异常传播，不能误把调用者 rescue 中的异常当成当前错误。
      raise failure if failure && completed
    end

    # 句柄清理失败不改变进程策略；未回收 PID 保留给重复关闭或终结器继续处理。
    def close_child(timeout:, term_timeout:, force:)
      return process_status unless @resources.owner == Process.pid && pid

      status = wait(timeout:)
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

    # 只结束读取方向并冲刷接收记录；EOF 不代表子进程已经退出或写端已经关闭。
    def mark_eof
      @eof = true
      flush_transcript
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
      # 丢弃的前缀使当前窗口与已转发历史之间不再连续。
      @relay_history.clear
    end

    # 仅由资源创建者向仍未回收的子进程发送信号；若进程刚好退出，则尝试回收。
    def signal_child(signal)
      return unless pid && @resources.owner == Process.pid

      Process.kill(signal, pid)
    rescue Errno::ESRCH
      @resources.reap
    end
  end
end
