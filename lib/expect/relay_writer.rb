# frozen_string_literal: true

class Expect
  # 向单个转接目标写入数据，维护发送进度与期限；恢复时不重放已成功写出的前缀。
  class RelayWriter
    attr_reader :target, :deadline

    def initialize(target, data)
      @target = target
      @data = data
      @offset = 0
      @flushed = false
      restart_timeout
    end

    def restart_timeout
      period = target.write_timeout if target.is_a?(Expect)
      @deadline = period && (Expect.monotonic + period)
    end

    def io
      return target.writer if target.is_a?(Expect)

      target if target.is_a?(IO)
    end

    def done? = @offset == @data.bytesize && @flushed

    # 每轮每目标至多一次写入；真实 IO 永不在此等待，交给 Relay 的共同 select。
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 游标、短写、flush 和期限按单个目标推进。
    def advance(check_timeout: true)
      return false if done?
      raise IOError, "closed Expect session" if target.is_a?(Expect) && target.closed?

      if @offset < @data.bytesize
        bytes = @data.byteslice(@offset, READ_SIZE)
        count = io ? io.write_nonblock(bytes, exception: false) : target.write(bytes)
        if count == :wait_writable
          check_timeout! if check_timeout
          return false
        end
        unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize
          raise IOError, "write must return the number of accepted bytes"
        end

        @offset += count
      end
      if @offset == @data.bytesize
        # write_nonblock 已直接写到底层；普通 write 对象仍遵守自身 flush 协议。
        target.flush if !io && target.respond_to?(:flush)
        @flushed = true
      end
      true
    rescue Errno::EINTR
      check_timeout! if check_timeout
      true
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def check_timeout!
      return unless deadline && Expect.monotonic >= deadline

      raise WriteTimeout.new("relay target write timed out", bytes_written: @offset)
    end
  end

  private_constant :RelayWriter
end
