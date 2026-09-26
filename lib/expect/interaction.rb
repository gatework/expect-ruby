# frozen_string_literal: true

require_relative "relay_writer"
require_relative "relay"

# 为会话补充人工接管和多路 IO 转接；核心会话定义位于 lib/expect.rb。
class Expect
  REGEXP_ESCAPE_HISTORY_LIMIT = 65_536
  private_constant :REGEXP_ESCAPE_HISTORY_LIMIT

  # Presents remote text on a raw local terminal without changing existing CRLF sequences.
  class InteractOutput
    def initialize(target)
      @target = target
      @previous_carriage_return = false
    end

    attr_reader :target

    def render(data)
      bytes = data.to_s.b
      rendered = bytes.gsub(/(?<!\r)\n/n, "\r\n")
      rendered = rendered.byteslice(1..) if @previous_carriage_return && bytes.start_with?("\n")
      @previous_carriage_return = bytes.end_with?("\r")
      rendered
    end

    def write(data)
      @target.write(render(data))
    end
  end

  private_constant :InteractOutput

  # 注册字面、正则转义或 :eof 事件；回调用闭包保存上下文，nil/false 停止，其余值继续。
  def on_sequence(sequence, &block)
    key = case sequence
          when :eof, Regexp then sequence
          when String then sequence.b.freeze
          else raise ArgumentError, "sequence must be a String, Regexp or :eof"
          end
    raise ArgumentError, "escape sequence must not be empty" if key == ""

    @sequences[key] = block
    self
  end

  # 临时将输入、会话和输出相连，实现人工接管；结束时恢复双方监听器、日志开关和转义设置。
  def interact(input: $stdin, escape: nil, output: nil, timeout: nil)
    source = interact_source(input)
    output ||= input.equal?($stdin) ? $stdout : input
    saved_self = [listeners, log_stdout, log_listeners]
    saved_source = [source.listeners, source.log_stdout, source.log_listeners, source.sequences.dup]
    terminal_state = prepare_interact_terminal(source)
    display = interact_display(source, output, terminal_state)
    # 临时建立“用户输入 -> 子进程 -> 显示输出”的双向连接，原监听关系在 ensure 中恢复。
    self.listeners = [display]
    self.log_stdout = false
    self.log_listeners = true
    source.listeners = [self]
    source.log_stdout = false
    source.log_listeners = true
    source.on_sequence(escape) if escape
    Expect.interconnect(self, source, timeout: timeout)
  ensure
    begin
      if saved_self
        self.listeners, self.log_stdout, self.log_listeners = saved_self
        source.listeners, source.log_stdout, source.log_listeners, source.sequences = saved_source
      end
    ensure
      restore_interact_terminal(terminal_state)
    end
  end

  # 按各会话 listeners 建立转发图，处理转义、EOF 和总期限，返回引发停止的会话或 nil。
  def self.interconnect(*sessions, timeout: nil)
    raise ArgumentError, "interconnect requires Expect sessions" if sessions.empty? || sessions.any? do |session|
      !session.is_a?(Expect)
    end

    Relay.new(sessions, timeout).run
  end

  # 超时或异常后仍有未交付的数据；重新 interconnect 同一源会话可继续发送。
  def pending_output? = @relay_outputs.any? { |output| !output.done? }

  # 转发一个会话的待处理缓冲并剔除转义；返回 false 表示应结束整个转接。
  # 字面序列暂存潜在前缀，正则序列结合历史匹配；final 为真时不再等待后续字节。
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 转义匹配、前缀暂存和回调消费属于同一轮扫描。
  def self.relay_buffer(session, buffers, final: false)
    buffer = buffers.fetch(session)
    loop do
      sequences = session.__send__(:sequences).except(:eof)
      history = session.__send__(:relay_history)
      text = nil
      utf8_regexp = false
      matches = sequences.filter_map do |key, handler|
        if key.is_a?(Regexp)
          # 仅在本轮扫描复用组合文本；回调可能更换规则或消费缓冲，下一轮必须重新构造。
          text ||= history + buffer
          utf8_regexp ||= key.fixed_encoding? && key.encoding == Encoding::UTF_8
          position = Pattern.new(value: key).locate(text, final: final)
          if position
            offset, length, = position
            raise ArgumentError, "escape regexp must consume at least one byte" if length.zero?

            # 历史前缀已实时转发，不能撤回；负偏移表示本次只需消费转义尚未转发的部分。
            [offset - history.bytesize, length, handler]
          end
        else
          position = buffer.index(key)
          [position, key.bytesize, handler] if position
        end
      end
      if (found = matches.min_by(&:first))
        position, length, callback = found
        if position.positive?
          if block_given?
            yield buffer.byteslice(0, position)
            buffer.replace(buffer.byteslice((position + length)..))
            history.clear
            # 已确定的转义不能在等待写入后重新匹配；尾部可能在等待期间继续增长。
            session.__send__(:relay_callback=, [callback])
            return :pending
          end
          session.__send__(:propagate, buffer.byteslice(0, position))
        end
        buffer.replace(buffer.byteslice([position + length, 0].max..))
        # 转义消费后清除历史，防止继续回调再次匹配同一个转义。
        history.clear
        return false unless callback&.call

        next
      end

      # 暂存可能构成字面转义的最长后缀，保证 STOP 分两次读取时 ST 不会提前发给子进程。
      held = 0
      unless final
        sequences.each_key do |key|
          next if key.is_a?(Regexp)

          [key.bytesize - 1, buffer.bytesize].min.downto(1) do |length|
            if buffer.end_with?(key.byteslice(0, length))
              held = [held, length].max
              break
            end
          end
        end
      end
      count = buffer.bytesize - held
      count = [count, READ_SIZE].min if block_given?
      if count.positive?
        data = buffer.byteslice(0, count)
        block_given? ? yield(data) : session.__send__(:propagate, data)
      end
      if text
        history << buffer.byteslice(0, count)
        limit = session.buffer_limit || REGEXP_ESCAPE_HISTORY_LIMIT
        if history.bytesize > limit
          history.replace(history.byteslice(-limit, limit))
          if utf8_regexp
            # 窗口可能从 UTF-8 续字节开始；丢弃不完整的首字符后再交给固定编码正则。
            history.slice!(0) while (byte = history.getbyte(0)) && (0x80..0xBF).cover?(byte)
          end
        end
      end
      buffer.slice!(0, count)
      return block_given? && count.positive? ? :pending : true
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private_class_method :relay_buffer

  def interact_source(input)
    return input if input.is_a?(Expect)

    @interact_inputs ||= {}.compare_by_identity
    @interact_inputs.delete_if { |io, session| io.closed? || session.closed? }
    @interact_inputs[input] ||= Expect.open(input)
  end

  def queue_output(data)
    targets = []
    targets << $stdout if log_stdout?
    targets.concat(@listeners) if log_listeners?
    @relay_outputs = targets.map do |target|
      if target.is_a?(InteractOutput)
        RelayWriter.new(target.target, target.render(data))
      else
        RelayWriter.new(target, data)
      end
    end
  end

  private :interact_source, :queue_output

  # Only interact knows which stream is the local keyboard. Generic interconnect leaves terminals alone.
  def prepare_interact_terminal(source)
    return unless source.raw_terminal? && source.tty?

    io = source.to_io
    state = [io, io.console_mode]
    io.raw!
    state
  rescue Exception # rubocop:disable Lint/RescueException -- Restore a partially changed terminal on interrupts.
    restore_interact_terminal(state)
    raise
  end

  def restore_interact_terminal(state)
    return unless state

    io, mode = state
    io.console_mode = mode unless io.closed?
  end

  def interact_display(source, output, terminal_state)
    @interact_output = nil unless terminal_state && @interact_output&.target.equal?(output)
    return output unless terminal_state

    target = output.respond_to?(:to_io) ? output.to_io : output
    return output unless target.respond_to?(:tty?) && target.tty?
    return output unless source.to_io.stat.rdev == target.stat.rdev

    # 同一输出的 CRLF 可能跨越两次接管；只缓存最近目标，避免长期持有旧终端。
    @interact_output ||= InteractOutput.new(output)
  rescue IOError, SystemCallError
    output
  end

  private :prepare_interact_terminal, :restore_interact_terminal, :interact_display

  protected

  # 仅供转接内部保存和恢复注册表，避免公开可变 Hash 绕过 on_sequence 的校验。
  attr_accessor :sequences
  # 让同步写入的背压读取遵守当前转接的数据所有权，退出后恢复普通匹配缓冲。
  attr_accessor :interaction_buffer
  attr_reader :relay_outputs
  attr_accessor :relay_callback

  # 历史属于产生它的转义规则；同规则重入继续匹配，换规则不能重放已转发输入。
  def relay_history
    sequences = @sequences.except(:eof)
    @relay_history = "".b unless @relay_history_sequences == sequences
    @relay_history_sequences = sequences
    @relay_history
  end

  # 转接尚未处理的输入不能被匹配窗口上限裁掉；下次 expect 会重新应用该上限。
  def restore_relay_buffer(buffer)
    @buffer = buffer + @buffer
  end
end
