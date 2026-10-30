# frozen_string_literal: true

require_relative "relay/writer"
require_relative "relay"
require_relative "literal_prefix"
require_relative "literal_scan"

# 为会话补充人工接管和多路 IO 转接；核心会话定义位于 session.rb。
module Expect
  # 为公开 Session 混入转义注册与人工接管接口；协作方法各自标记为内部协议。
  # 宿主提供真实读写 IO 和缓冲；本模块保存输出目标、转义、显示历史和待写游标。
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

      self.sequences = @sequences.merge(key => block || STOP).freeze
      self
    end

    # 临时将输入、会话和输出相连，实现人工接管；结束时恢复双方输出目标、转义和终端模式。
    def interact(input: $stdin, escape: nil, output: nil, timeout: nil, raw: true)
      source = interact_source(input)
      output = input.equal?($stdin) ? $stdout : input if output.nil?
      saved_self = outputs
      saved_source = [source.outputs, source.sequences.dup]
      terminal_state = prepare_interact_terminal(source) if raw
      # 先持有恢复快照，再在同一清理作用域内切换终端；返回值交接中断不能留下 raw 模式。
      Cleanup.always(-> { restore_interact(source, saved_self, saved_source, terminal_state) }) do
        terminal_state&.first&.raw!
        display = interact_display(source, output, terminal_state)
        self.outputs = [display]
        source.outputs = [self]
        source.on_sequence(escape) unless escape.nil?
        Relay.new([self, source], timeout).run
      end
    end

    # 超时或异常后仍有未交付的数据；重新 interconnect 同一源会话可继续发送。
    def pending_output? = @pending_writes.any? { |output| !output.done? }

    # 返回协议转发目标的副本，外部修改不能原地改变转发图。
    def outputs = @outputs.dup

    # 先校验整个数组再替换，失败时保留原输出图；目标始终由调用方拥有。
    def outputs=(targets)
      unless targets.is_a?(Array) && targets.all? { |target| target.respond_to?(:write) }
        raise ArgumentError, "outputs must be an Array of writers"
      end

      @outputs = targets.dup
    end

    # 普通接收同步交付原始字节；日志脱敏不影响协议输出。
    # @api private
    def propagate(data)
      @outputs.each { |output| emit(output, data) }
    end

    # 将待处理输入排入唯一的转接发送队列；返回 :ready、:queued、:stopped 或 :timeout。
    # 字面序列暂存潜在前缀，正则序列结合历史匹配；final 为真时不再等待后续字节。
    # @api private
    def self.queue_input(session, buffer, final: false, deadline: nil, literal_scan: nil)
      loop do
        sequences = session.text_sequences
        history = session.relay_history
        found, regexp_scanned, utf8_regexp = scan_sequences(
          buffer, sequences, history, final:, literal_scan:, generation: session.buffer_generation,
                                      compiled: session.sequence_patterns
        )
        return :timeout if expired?(deadline)

        if found
          literal_scan&.reset
          result = handle_escape(session, buffer, history, found)
          return result unless result == :ready
          return :timeout if expired?(deadline)

          next
        end

        # 暂存可能构成字面转义的最长后缀，保证 STOP 分两次读取时 ST 不会提前发给子进程。
        held = final ? 0 : hold_literal_prefix(buffer, sequences, session.literal_prefix_tables)
        return :timeout if expired?(deadline)

        count = [buffer.bytesize - held, READ_SIZE].min
        session.queue_output(buffer.byteslice(0, count)) if count.positive?
        if regexp_scanned
          trim_history(history, buffer.byteslice(0, count), limit: session.buffer_limit || REGEXP_ESCAPE_HISTORY_LIMIT,
                                                            utf8: utf8_regexp)
        end
        # 排队前缀与尾部可共享原字节；替换窗口而非删除前缀，避免逐块复制整个余量。
        # 保留缓冲对象身份，嵌套 Matcher 仍把尾部交回 Relay 借用的同一个对象。
        if count.positive?
          buffer.replace(buffer.byteslice(count..))
          literal_scan&.advance(count)
        end
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
    def self.scan_sequences(buffer, sequences, history, final:, literal_scan: nil, generation: nil, compiled: {})
      text = nil
      utf8_regexp = false
      earliest = nil
      earliest_offset = Float::INFINITY
      # 只保存最早候选，同位置不替换先注册者；仍扫描全部正则以校验零宽规则并收集编码状态。
      sequences.each do |key, handler|
        if key.is_a?(Regexp)
          # 仅在本轮扫描复用组合文本；回调可能更换规则或消费缓冲，下一轮必须重新构造。
          text ||= history + buffer
          utf8_regexp ||= key.fixed_encoding? && key.encoding == Encoding::UTF_8
          pattern = compiled.fetch(key) { Pattern.new(value: key) }
          position = pattern.locate(text, final:, captures: false)
          next unless position

          offset, length, = position
          raise ArgumentError, "escape regexp must consume at least one byte" if length.zero?

          # 历史前缀已实时转发，不能撤回；负偏移表示本次只需消费转义尚未转发的部分。
          offset -= history.bytesize
        else
          offset = literal_scan ? literal_scan.index(buffer, key, generation:) : buffer.index(key)
          next unless offset

          length = key.bytesize
        end
        if offset < earliest_offset
          earliest = [offset, length, handler]
          earliest_offset = offset
        end
      end
      [earliest, !text.nil?, utf8_regexp]
    end

    # 普通转发和超时排出的字面前缀都属于正则历史，跨次转接时必须接续同一字节流。
    # @api private
    def self.remember_output(session, data)
      return if session.sequence_patterns.empty?

      trim_history(session.relay_history, data, limit: session.buffer_limit || REGEXP_ESCAPE_HISTORY_LIMIT,
                                                utf8: session.utf8_sequences?)
    end

    # 只暂存可能拼成完整字面转义的最长后缀。
    def self.hold_literal_prefix(buffer, sequences, prefix_tables = {})
      held = 0
      sequences.each_key do |key|
        next if key.is_a?(Regexp)

        prefix_length = LiteralPrefix.length(buffer, key, prefix_tables)
        held = prefix_length if prefix_length > held
      end
      held
    end

    # 已转发历史有界保留，固定 UTF-8 正则不能从续字节开始匹配。
    def self.trim_history(history, data, limit:, utf8:)
      history << data
      # 四字节 UTF-8 字符在下一片到来前最多需要保留三个字节；小窗口不能截掉这段编码状态。
      limit = [limit, 3].max if utf8
      return unless history.bytesize > limit

      # 保留历史对象身份，但独立复制尾部，释放已经转发的大前缀存储。
      history.replace(history.unpack1("a*", offset: history.bytesize - limit))
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
          Relay::Writer.new(target.target, target.render(data))
        else
          Relay::Writer.new(target, data)
        end
      end
    end

    # 冻结的注册快照只能通过 on_sequence 或内部恢复入口替换，不能绕过编译及历史失效。
    # @api private
    attr_reader :sequences

    # @api private
    def sequences=(sequences)
      # Hash 的值相等忽略插入顺序；转义优先级必须同时比较声明顺序。
      return if @sequences == sequences && @sequences.keys == sequences.keys

      @sequences = sequences.frozen? ? sequences : sequences.dup.freeze
      @literal_prefix_tables.delete_if { |sequence, _table| !sequences.key?(sequence) }
    end

    # 连续声明只发布注册快照；首次扫描统一编译，后续读取不重复创建集合及正则包装。
    # @api private
    def text_sequences
      return @text_sequences if @compiled_sequences.equal?(@sequences)

      registered = @sequences
      text = registered.except(:eof).freeze
      patterns = text.each_key.with_object({}) do |key, patterns|
        patterns[key] = @sequence_patterns[key] || Pattern.new(value: key) if key.is_a?(Regexp)
      end.freeze
      utf8 = patterns.each_key.any? do |regexp|
        regexp.fixed_encoding? && regexp.encoding == Encoding::UTF_8
      end
      # 编译结果一起发布；失败时旧缓存仍完整，下次扫描可以重新编译，不读取陈旧规则。
      Thread.handle_interrupt(Object => :never) do
        @text_sequences = text
        @sequence_patterns = patterns
        @utf8_sequences = utf8
        @compiled_sequences = registered
      end
      text
    end

    # 冻结的正则包装快照；已存在的正则跨规则变更复用。
    # @api private
    def sequence_patterns
      text_sequences
      @sequence_patterns
    end

    # 正则历史的编码边界由当前已注册规则决定。
    # @api private
    def utf8_sequences?
      text_sequences
      @utf8_sequences
    end
    # 冻结字面规则对应的 KMP 前缀表，跨转接复用，避免每个读块重新编译长规则。
    # @api private
    attr_reader :literal_prefix_tables
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
      # interact 的临时注册和恢复不消费输入；只比较实际扫描时的规则，保留同规则跨次接管的历史。
      sequences = text_sequences
      @relay_history.clear unless @relay_history_sequences == sequences
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

    # 转接状态集中在所属模块初始化；缓冲和进程状态仍由 Session 管理。
    def initialize_interaction
      @outputs = []
      @sequences = {}.freeze
      @text_sequences = @sequence_patterns = @sequences
      @compiled_sequences = @sequences
      @utf8_sequences = false
      @literal_prefix_tables = {}
      @pending_writes = []
      @interact_inputs = {}.compare_by_identity
      @interact_output = nil
      @interaction_buffer = @relay_owner = @relay_callback = nil
      @relay_history = "".b
      @relay_history_sequences = @text_sequences
    end

    # 同一输入 IO 重用一个借用会话，以保留上次接管预读的尾部并避免不断积累包装器。
    def interact_source(input)
      return input if input.is_a?(Session)

      @interact_inputs.delete_if { |io, session| io.closed? || session.closed? }
      @interact_inputs[input] ||= Expect.open(input)
    end

    # 只取得快照；实际 raw! 由持有快照的 interact 在清理作用域内执行。
    def prepare_interact_terminal(source)
      return unless source.tty?

      io = source.to_io
      [io, io.console_mode]
    end

    # 独立尝试每项恢复；常规恢复错误不能覆盖业务主异常，新的中断仍按 Cleanup 契约传播。
    def restore_interact(source, saved_self, saved_source, terminal_state)
      Cleanup.always(-> { restore_interact_terminal(terminal_state) }) do
        Cleanup.always(-> { source.sequences = saved_source.last }) do
          Cleanup.always(-> { source.outputs = saved_source.first }) { self.outputs = saved_self }
        end
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
