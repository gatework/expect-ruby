# frozen_string_literal: true

class Expect
  # 一次转接的共同读写循环；发送游标留在源会话中，调用结束后仍可继续。
  # 本对象只暂借未处理输入；读缓冲、发送进度与转义回调分开保存，避免重入时重复交付。
  class Relay
    # 将普通匹配缓冲移入本轮转接，并记住上层交互缓冲；不关闭或接管任何外部 IO。
    def initialize(sessions, timeout)
      @sessions = sessions.uniq
      @active = @sessions.dup
      period = Expect.duration(timeout)
      @deadline = period && (Expect.monotonic + period)
      @buffers = @sessions.to_h { |session| [session, session.clear_buffer] }
      @previous = @sessions.to_h { |session| [session, session.__send__(:interaction_buffer)] }
    end

    # 每轮先处理转义和已排队输出，再共同选择读写；停止返回来源会话，总期限到达返回 nil。
    # 真实 IO 的写入由非阻塞游标推进，用户日志和回调仍同步执行，须由调用方保证及时返回。
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 共享读写循环统一维护来源和目标期限。
    def run
      @sessions.each { |session| session.__send__(:interaction_buffer=, @buffers.fetch(session)) }
      outputs.each(&:restart_timeout)
      polled = false
      loop do
        idle = []
        queued = false
        @active.dup.each do |session|
          next if session.pending_output?

          if (callback = session.__send__(:relay_callback))
            session.__send__(:relay_callback=, nil)
            return session unless callback.first&.call
          end

          result = Expect.__send__(:relay_buffer, session, @buffers, final: session.eof?) do |data|
            session.__send__(:queue_output, data)
          end
          return session unless result

          if result == :pending
            queued = true
            next
          end

          idle << session
          next unless session.eof?

          callback = session.__send__(:sequences)[:eof]
          return session unless callback&.call

          @active.delete(session)
        end
        return nil if @active.empty?

        return finish_timeout(idle) if polled && expired?

        progress = advance_outputs || queued

        pending = outputs
        readers = read_sources(pending)
        deadlines = [@deadline, *pending.map(&:deadline)].compact
        remaining = deadlines.empty? ? nil : [deadlines.min - Expect.monotonic, 0].max
        # 有进展时轮询输入再继续发送，避免大块输出饿死其他来源。
        remaining = 0 if progress
        begin
          polled = true
          ready = IO.select(readers.map(&:to_io), pending.filter_map(&:io).uniq, nil, remaining)
          if ready
            readers.each do |session|
              next unless ready[0].include?(session.to_io)

              begin
                if @buffers.key?(session)
                  session.__send__(:read_available, propagate: false, buffer: @buffers.fetch(session), trim: false)
                else
                  session.__send__(:read_available, propagate: false)
                end
              rescue Errno::EINTR
                next
              end
            end
          elsif !progress
            return finish_timeout(idle) if expired?

            pending.each(&:check_timeout!)
          end
        rescue Errno::EINTR
          next
        end
      end
    ensure
      # 未处理输入还给会话，已排队字节仍归发送游标；两者不能合并，否则恢复会重放前缀。
      @previous.each { |session, buffer| session.__send__(:interaction_buffer=, buffer) }
      @buffers.each { |session, buffer| session.__send__(:restore_relay_buffer, buffer) }
    end

    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    private

    # 只收集尚未完成的目标，供共同 select 以及最早写入期限计算使用。
    def outputs = @sessions.flat_map { |session| session.__send__(:relay_outputs) }.reject(&:done?)

    # 每个目标每轮最多推进一个片段；移除已完成游标，并告知主循环是否值得立即继续轮询。
    def advance_outputs(check_timeout: true)
      progress = false
      @sessions.each do |session|
        pending = session.__send__(:relay_outputs)
        pending.each { |output| progress = output.advance(check_timeout: check_timeout) || progress }
        pending.reject!(&:done?)
      end
      progress
    end

    # 转接总期限不因持续输入或某个目标的写入进展而重置。
    def expired? = @deadline && Expect.monotonic >= @deadline

    # 背压源暂停吸收新输入，限制排队增长；作为写入目标的会话仍需读取以解除双向等待。
    def read_sources(pending)
      # 输出目标可能也在等待我们读取；这些来源即使有待发送数据也必须继续排空。
      targets = pending.map(&:target).grep(Expect)
      sources = @active.reject { |session| session.pending_output? && !targets.include?(session) }
      (sources + targets).uniq(&:to_io).reject(&:eof?)
    end

    # 总期限结束时将可交付尾部转为发送游标，至多尝试一轮交付；余量由源会话保存。
    # 目标的写期限更早到达时保留 WriteTimeout 语义，不能被转接的普通超时掩盖。
    def finish_timeout(idle)
      # 调度延迟可能让两种期限均已到达，仍按先到的期限决定结果。
      outputs.each { |output| output.check_timeout! if output.deadline && output.deadline < @deadline }
      idle.each do |session|
        next if session.pending_output?

        buffer = @buffers.fetch(session)
        next if buffer.empty?

        session.__send__(:queue_output, buffer.dup)
        buffer.clear
      end
      # 到期后只尝试一次非阻塞写入，剩余游标留给下一次 interconnect。
      advance_outputs(check_timeout: false)
      nil
    end
  end

  private_constant :Relay
end
