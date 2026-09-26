# frozen_string_literal: true

class Expect
  # 一次转接的共同读写循环；发送游标留在源会话中，调用结束后仍可继续。
  class Relay
    def initialize(sessions, timeout)
      @sessions = sessions.uniq
      @active = @sessions.dup
      period = Expect.duration(timeout)
      @deadline = period && (Expect.monotonic + period)
      @buffers = @sessions.to_h { |session| [session, session.clear_buffer] }
      @previous = @sessions.to_h { |session| [session, session.__send__(:interaction_buffer)] }
    end

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
      @previous.each { |session, buffer| session.__send__(:interaction_buffer=, buffer) }
      @buffers.each { |session, buffer| session.__send__(:restore_relay_buffer, buffer) }
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    private

    def outputs = @sessions.flat_map { |session| session.__send__(:relay_outputs) }.reject(&:done?)

    def advance_outputs(check_timeout: true)
      progress = false
      @sessions.each do |session|
        pending = session.__send__(:relay_outputs)
        pending.each { |output| progress = output.advance(check_timeout: check_timeout) || progress }
        pending.reject!(&:done?)
      end
      progress
    end

    def expired? = @deadline && Expect.monotonic >= @deadline

    def read_sources(pending)
      # 输出目标可能也在等待我们读取；这些来源即使有待发送数据也必须继续排空。
      targets = pending.map(&:target).grep(Expect)
      sources = @active.reject { |session| session.pending_output? && !targets.include?(session) }
      (sources + targets).uniq(&:to_io).reject(&:eof?)
    end

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
