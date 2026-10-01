# frozen_string_literal: true

class Expect
  # 向单个转接目标写入数据，维护发送进度与期限；恢复时不重放已成功写出的前缀。
  # 只借用目标，不 dup 描述符，也不负责读取；所有就绪等待统一交给 Relay 调度。
  # @api private
  class RelayWriter
    attr_reader :target, :deadline

    # data 在本游标存活期间由上层保持不变，offset 始终以实际交付的字节数计量。
    def initialize(target, data)
      @target = target
      @data = data
      @offset = 0
      @flushed = false
      restart_timeout
    end

    # 初次排队或重新进入 interconnect 时开始新的写入预算；普通短写不会刷新期限。
    # 只有 Expect 目标提供 write_timeout，原生 IO 和自定义目标只受转接总期限约束。
    def restart_timeout
      period = target.write_timeout if target.is_a?(Expect)
      @deadline = period && (Expect.monotonic + period)
    end

    # 真实 IO 可参与共同 select；自定义可写对象返回 nil，沿用其同步 write/flush 协议。
    def io
      return target.writer if target.is_a?(Expect)

      target if target.is_a?(IO)
    end

    # 数据交付完但 flush 失败仍未完成；重试只补 flush，不重新发送已接受的数据。
    def done? = @offset == @data.bytesize && @flushed

    # 每轮每目标至多一次写入；真实 IO 永不在此等待，交给 Relay 的共同 select。
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 游标、短写、flush 和期限按单个目标推进。
    def advance(check_timeout: true)
      return false if done?
      raise IOError, "closed Expect session" if target.is_a?(Expect) && target.closed?

      if @offset < @data.bytesize
        bytes = @data.byteslice(@offset, READ_SIZE)
        count = io ? io.write_nonblock(bytes, exception: false) : target.write(bytes)
        if io && count == :wait_writable
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
      # 未获得写入计数就不移动游标；先检查原期限，再让共同循环轮询输入并重试。
      check_timeout! if check_timeout
      true
    end

    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # 保留本数据块已交付的进度，便于调用方区分未写入和部分写入；不清空恢复用的游标。
    def check_timeout!
      return unless deadline && Expect.monotonic >= deadline

      raise WriteTimeout.new("relay target write timed out", bytes_written: @offset)
    end
  end

  private_constant :RelayWriter
end
