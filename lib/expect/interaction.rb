# frozen_string_literal: true

require_relative "relay_writer"
require_relative "relay"

# 为会话补充人工接管和多路 IO 转接；核心会话定义位于 session.rb。
module Expect
  # 为公开 Session 混入转义注册与人工接管接口；协作方法各自标记为内部协议。
  # 宿主提供真实读写 IO、缓冲及 outputs；本模块保存转义、显示历史和待写游标。
  # Relay 暂借输入缓冲并调度游标，Matcher 可在转义回调中临时接管，退出时归还未消费尾部。
  module Interaction
    # 正则没有“潜在部分匹配”接口，只保留有限历史；已转发的历史字节不能撤回。
    REGEXP_ESCAPE_HISTORY_LIMIT = 65_536
    # 没有显式回调的转义仍用同一 callable 协议，返回 false 让 Relay 停止。
    STOP = -> { false }.freeze
    private_constant :REGEXP_ESCAPE_HISTORY_LIMIT, :STOP

    # 在 raw 本地终端显示远端文本，补齐 LF 所需的 CR，同时保留已有 CRLF。
    # @api private
    class InteractOutput
      # 包装器借用目标，不复制或关闭其描述符；换行状态属于这个目标的连续显示流。
      def initialize(target)
        @target = target
        @previous_carriage_return = false
      end

      attr_reader :target

      # 只改变显示字节，不改写匹配输入；记住上一块的 CR，避免分块的 CRLF 被扩成 CRCRLF。
      def render(data)
        bytes = data.to_s.b
        rendered = bytes.gsub(/(?<!\r)\n/n, "\r\n")
        rendered = rendered.byteslice(1..) if @previous_carriage_return && bytes.start_with?("\n")
        @previous_carriage_return = bytes.end_with?("\r")
        rendered
      end

      # 提供普通可写对象接口；Relay 会先 render，再按转换后字节数维护独立发送游标。
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

      @sequences[key] = block || STOP
      self
    end

    # 临时将输入、会话和输出相连，实现人工接管；结束时恢复双方输出目标、转义和终端模式。
    def interact(input: $stdin, escape: nil, output: nil, timeout: nil, raw: true)
      source = interact_source(input)
      output = input.equal?($stdin) ? $stdout : input if output.nil?
      saved_self = outputs
      saved_source = [source.outputs, source.sequences.dup]
      terminal_state = prepare_interact_terminal(source) if raw
      display = interact_display(source, output, terminal_state)
      # 临时建立“用户输入 -> 子进程 -> 显示输出”的双向连接，原监听关系在 ensure 中恢复。
      self.outputs = [display]
      source.outputs = [self]
      source.on_sequence(escape) unless escape.nil?
      Relay.new([self, source], timeout).run
    ensure
      begin
        if saved_self
          self.outputs = saved_self
          source.outputs, source.sequences = saved_source
        end
      ensure
        restore_interact_terminal(terminal_state)
      end
    end

    # 超时或异常后仍有未交付的数据；重新 interconnect 同一源会话可继续发送。
    def pending_output? = @pending_writes.any? { |output| !output.done? }

    # 将待处理输入排入唯一的转接发送队列；返回 :ready、:queued、:stopped 或 :timeout。
    # 字面序列暂存潜在前缀，正则序列结合历史匹配；final 为真时不再等待后续字节。
    # @api private
    def self.queue_input(session, buffer, final: false, deadline: nil)
      loop do
        sequences = session.sequences.except(:eof)
        history = session.relay_history
        found, regexp_scanned, utf8_regexp = scan_sequences(buffer, sequences, history, final:)
        return :timeout if expired?(deadline)

        if found
          result = handle_escape(session, buffer, history, found)
          return result unless result == :ready
          return :timeout if expired?(deadline)

          next
        end

        # 暂存可能构成字面转义的最长后缀，保证 STOP 分两次读取时 ST 不会提前发给子进程。
        held = final ? 0 : hold_literal_prefix(buffer, sequences)
        return :timeout if expired?(deadline)

        count = [buffer.bytesize - held, READ_SIZE].min
        session.queue_output(buffer.byteslice(0, count)) if count.positive?
        if regexp_scanned
          trim_history(history, buffer.byteslice(0, count), limit: session.buffer_limit || REGEXP_ESCAPE_HISTORY_LIMIT,
                                                            utf8: utf8_regexp)
        end
        buffer.slice!(0, count)
        return count.positive? ? :queued : :ready
      end
    end

    # 单轮扫描和同步回调恢复控制后才检查预算，不能强行中断用户代码。
    def self.expired?(deadline) = !deadline.nil? && Expect.monotonic >= deadline

    # 转义前缀必须交付完才运行回调；有前缀时保存回调，交给 Relay 交付后再执行。
    def self.handle_escape(session, buffer, history, found)
      position, length, callback = found
      if position.positive?
        session.queue_output(buffer.byteslice(0, position))
        buffer.replace(buffer.byteslice((position + length)..))
        history.clear
        # 已确定的转义不能在等待写入后重新匹配；尾部可能在等待期间继续增长。
        session.relay_callback = callback
        return :queued
      end
      buffer.replace(buffer.byteslice([position + length, 0].max..))
      # 转义消费后清除历史，防止继续回调再次匹配同一个转义。
      history.clear
      callback&.call ? :ready : :stopped
    end

    # 单轮正则共用一个组合文本；回调返回后下一轮重新取得规则和历史。
    def self.scan_sequences(buffer, sequences, history, final:)
      text = nil
      utf8_regexp = false
      matches = sequences.filter_map do |key, handler|
        if key.is_a?(Regexp)
          # 仅在本轮扫描复用组合文本；回调可能更换规则或消费缓冲，下一轮必须重新构造。
          text ||= history + buffer
          utf8_regexp ||= key.fixed_encoding? && key.encoding == Encoding::UTF_8
          position = Pattern.new(value: key).locate(text, final:)
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
      [matches.min_by(&:first), !text.nil?, utf8_regexp]
    end

    # 普通转发和超时排出的字面前缀都属于正则历史，跨次转接时必须接续同一字节流。
    # @api private
    def self.remember_output(session, data)
      regexps = session.sequences.keys.grep(Regexp)
      return if regexps.empty?

      utf8 = regexps.any? { |regexp| regexp.fixed_encoding? && regexp.encoding == Encoding::UTF_8 }
      trim_history(session.relay_history, data, limit: session.buffer_limit || REGEXP_ESCAPE_HISTORY_LIMIT, utf8:)
    end

    # 只暂存可能拼成完整字面转义的最长后缀。
    def self.hold_literal_prefix(buffer, sequences)
      held = 0
      sequences.each_key do |key|
        next if key.is_a?(Regexp)

        [key.bytesize - 1, buffer.bytesize].min.downto(1) do |prefix_length|
          next unless buffer.end_with?(key.byteslice(0, prefix_length))

          held = [held, prefix_length].max
          break
        end
      end
      held
    end

    # 已转发历史有界保留，固定 UTF-8 正则不能从续字节开始匹配。
    def self.trim_history(history, data, limit:, utf8:)
      history << data
      return unless history.bytesize > limit

      history.replace(history.byteslice(-limit, limit))
      return unless utf8

      history.slice!(0) while (byte = history.getbyte(0)) && (0x80..0xBF).cover?(byte)
    end

    private_class_method :expired?, :handle_escape, :scan_sequences, :hold_literal_prefix, :trim_history

    # 为当前数据块冻结目标选择并各建一个发送游标；此后修改 outputs 只影响后续数据。
    # 调用方须先排空旧游标；显示转换也只做一次，短写重试时不能重复转换 CRLF。
    # @api private
    def queue_output(data)
      @pending_writes = @outputs.map do |target|
        if target.is_a?(InteractOutput)
          RelayWriter.new(target.target, target.render(data))
        else
          RelayWriter.new(target, data)
        end
      end
    end

    public

    # 仅供转接内部保存和恢复注册表，避免公开可变 Hash 绕过 on_sequence 的校验。
    # @api private
    attr_accessor :sequences
    # 让同步写入的背压读取遵守当前转接的数据所有权，退出后恢复普通匹配缓冲。
    # @api private
    attr_accessor :interaction_buffer
    # 活跃 Relay 的所有权 token；只限制同源递归转接，不限制转义回调中的 Matcher。
    # @api private
    attr_accessor :relay_owner
    # 只有裁剪、替换和消费才改变代次；同一代次只会追加，供字面扫描复用已排除的前缀。
    # @api private
    attr_reader :buffer_generation
    # 待交付游标随源会话保存，Relay 的超时或异常退出不会丢失各目标已经写出的进度。
    # @api private
    attr_reader :pending_writes
    # 等待前缀交付的动作；缺省停止动作也是真正的 callable，不使用数组包装状态。
    # @api private
    attr_accessor :relay_callback

    # 同规则保留跨次转接的连续历史；换规则或消费、改写输入后，不能拼接旧的前缀。
    # @api private
    def relay_history
      sequences = @sequences.except(:eof)
      @relay_history = "".b unless @relay_history_sequences == sequences
      @relay_history_sequences = sequences
      @relay_history
    end

    # 转接尚未处理的输入不能被匹配窗口上限裁掉；下次 expect 会重新应用该上限。
    # @api private
    def restore_relay_buffer(buffer)
      @buffer = buffer + @buffer
      @buffer_generation += 1
    end

    private

    # 同一输入 IO 重用一个借用会话，以保留上次接管预读的尾部并避免不断积累包装器。
    def interact_source(input)
      return input if input.is_a?(Session)

      @interact_inputs.delete_if { |io, session| io.closed? || session.closed? }
      @interact_inputs[input] ||= Expect.open(input)
    end

    # 只有 interact 知道哪个流是本地键盘；通用 interconnect 不修改终端模式。
    def prepare_interact_terminal(source)
      return unless source.tty?

      state = nil
      Cleanup.on_failure(-> { restore_interact_terminal(state) }) do
        io = source.to_io
        state = [io, io.console_mode]
        io.raw!
        state
      end
    end

    # 还原 prepare 保存的完整终端模式；没有切换过或句柄已关闭时无需恢复。
    def restore_interact_terminal(state)
      return unless state

      io, mode = state
      io.console_mode = mode unless io.closed?
    end

    # 仅为已切为 raw 的同一个本地终端补齐换行，文件、管道和其他终端保留原字节。
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
  end
end
