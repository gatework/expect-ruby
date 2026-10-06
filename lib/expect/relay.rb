# frozen_string_literal: true

module Expect
  # 一次转接的共同读写循环；发送游标留在源会话中，调用结束后仍可继续。
  # 本对象只暂借未处理输入；读缓冲、发送进度与转义回调分开保存，避免重入时重复交付。
  # @api private
  class Relay
    # 只串行化来源归属交接；Session 的其他操作仍须由调用方避免并发修改。
    OWNERSHIP_MUTEX = Mutex.new
    private_constant :OWNERSHIP_MUTEX

    # 这里只校验参数；run 取得所有来源后才转移缓冲，不关闭或接管任何外部 IO。
    def initialize(sessions, timeout)
      @sessions = sessions.uniq(&:object_id)
      @active = @sessions.dup
      period = Expect.duration(timeout)
      @deadline = period && (Expect.monotonic + period)
      # 零超时保留首轮缓冲及一次轮询；正预算在扫描和每次回调之间重新检查。
      @dispatch_deadline = @deadline unless period&.zero?
      @token = Object.new
      @buffers = {}.compare_by_identity
      @previous = {}.compare_by_identity
    end

    # 每轮先处理转义和已排队输出，再共同选择读写；停止返回来源会话，总期限到达返回 nil。
    # 真实 IO 的写入由非阻塞游标推进，用户日志和回调仍同步执行，须由调用方保证及时返回。
    def run
      prepare_sources
      pending_writes.each(&:restart_timeout)
      polled = false
      loop do
        stopped, idle, queued = dispatch_sources
        return finish_timeout(idle) if :timeout.equal?(stopped)
        return stopped if stopped

        return nil if @active.empty?

        return finish_timeout(idle) if polled && expired?

        progress = advance_outputs || queued

        polled = true
        return finish_timeout(idle) if select_and_read(progress) == :timeout
      end
    ensure
      restore_sources
    end

    private

    # 先交付转义前缀再派发回调；EOF 只在待发送数据处理完后生效。
    def dispatch_sources
      idle = []
      queued = false
      @active.dup.each do |session|
        return [:timeout, idle, queued] if dispatch_expired?

        next if session.pending_output?

        result = dispatch_input(session)
        return [session, idle, queued] if result == :stopped
        return [:timeout, idle, queued] if result == :timeout

        if result == :queued
          queued = true
          next
        end

        idle << session
        next unless session.eof?

        callback = session.sequences[:eof]
        return [session, idle, queued] unless callback&.call

        @active.delete_if { |active| active.equal?(session) }
        return [:timeout, idle, queued] if dispatch_expired?
      end
      [nil, idle, queued]
    end

    # 前缀交付完才调用延迟动作；动作耗尽预算后，尚未扫描的输入留给下次转接。
    def dispatch_input(session)
      if (callback = session.relay_callback)
        session.relay_callback = nil
        return :stopped unless callback.call
        return :timeout if dispatch_expired?
      end

      Interaction.queue_input(session, @buffers.fetch(session), final: session.eof?, deadline: @dispatch_deadline)
    end

    # 共同等待来源与目标，每轮读每个就绪来源一次；EINTR 返回原期限循环。
    def select_and_read(progress)
      pending = pending_writes
      readers = read_sources(pending)
      deadlines = [@deadline, *pending.map(&:deadline)].compact
      remaining = deadlines.empty? ? nil : [deadlines.min - Expect.monotonic, 0].max
      # 有进展时轮询输入再继续发送，避免大块输出饿死其他来源。
      remaining = 0 if progress
      begin
        ready = IO.select(readers.map(&:to_io), pending.filter_map(&:io).uniq(&:object_id), nil, remaining)
        if ready
          read_ready(readers, ready.first)
        elsif !progress
          return :timeout if expired?

          pending.each(&:check_timeout!)
        end
      rescue Errno::EINTR
        nil
      end
      nil
    end

    # 同源转接期间读取到借用缓冲；目标会话的背压读取沿用自身状态。
    def read_ready(readers, readable)
      return if readable.empty?

      if readable.size > 1
        ready = {}.compare_by_identity
        readable.each { |io| ready[io] = true }
      end
      readers.each do |session|
        next unless ready ? ready.key?(session.to_io) : readable.first.equal?(session.to_io)

        begin
          if @buffers.key?(session)
            session.read_available(propagate: false, buffer: @buffers.fetch(session), trim: false)
          else
            session.read_available(propagate: false)
          end
        rescue Errno::EINTR
          next
        end
      end
    end

    # 锁仅保护标记检查/登记，不跨 IO 或用户回调；任一来源被占用时整组拒绝，不动缓冲和期限。
    def prepare_sources
      OWNERSHIP_MUTEX.synchronize do
        raise ReentrancyError, "source session already has an active relay" if @sessions.any?(&:relay_owner)

        @sessions.each { |session| session.relay_owner = @token }
      end
      @sessions.each do |session|
        @previous[session] = session.interaction_buffer
        @buffers[session] = session.take_buffer
        session.interaction_buffer = @buffers.fetch(session)
      end
    end

    # 未处理输入还给会话，已排队字节仍归游标；构造中断也只恢复已转移的缓冲及自己的标记。
    def restore_sources
      @previous.each { |session, buffer| session.interaction_buffer = buffer }
      @buffers.each { |session, buffer| session.restore_relay_buffer(buffer) }
    ensure
      OWNERSHIP_MUTEX.synchronize do
        @sessions.each do |session|
          session.relay_owner = nil if session.relay_owner.equal?(@token)
        end
      end
    end

    # 只收集尚未完成的目标，供共同 select 以及最早写入期限计算使用。
    def pending_writes = @sessions.flat_map(&:pending_writes).reject(&:done?)

    # 每个目标每轮最多推进一个片段；移除已完成游标，并告知主循环是否值得立即继续轮询。
    def advance_outputs(check_timeout: true)
      progress = false
      @sessions.each do |session|
        pending = session.pending_writes
        pending.each { |output| progress = output.advance(check_timeout:) || progress }
        pending.reject!(&:done?)
      end
      progress
    end

    # 转接总期限不因持续输入或某个目标的写入进展而重置。
    def expired? = !@deadline.nil? && Expect.monotonic >= @deadline

    # 回调结束后只暂停后续工作，不打断当前用户代码，也不消费尚未扫描的转义尾部。
    def dispatch_expired? = !@dispatch_deadline.nil? && Expect.monotonic >= @dispatch_deadline

    # 背压源暂停吸收新输入，限制排队增长；作为写入目标的会话仍需读取以解除双向等待。
    def read_sources(pending)
      # 输出目标可能也在等待我们读取；这些来源即使有待发送数据也必须继续排空。
      targets = pending.filter_map do |output|
        output.target if output.target.is_a?(Session)
      end
      sources = @active.reject do |session|
        session.pending_output? && targets.none? { |target| target.equal?(session) }
      end
      (sources + targets).uniq { |session| session.to_io.object_id }.reject(&:eof?)
    end

    # 总期限结束时将可交付尾部转为发送游标，至多尝试一轮交付；余量由源会话保存。
    # 目标的写期限更早到达时保留 WriteTimeout 语义，不能被转接的普通超时掩盖。
    def finish_timeout(idle)
      # 调度延迟可能让两种期限均已到达，仍按先到的期限决定结果。
      pending_writes.each { |output| output.check_timeout! if output.deadline && output.deadline < @deadline }
      idle.each do |session|
        next if session.pending_output?

        buffer = @buffers.fetch(session)
        next if buffer.empty?

        session.queue_output(buffer.dup)
        Interaction.remember_output(session, buffer)
        buffer.clear
      end
      # 到期后只尝试一次非阻塞写入，剩余游标留给下一次 interconnect。
      advance_outputs(check_timeout: false)
      nil
    end
  end

  private_constant :Relay
end
