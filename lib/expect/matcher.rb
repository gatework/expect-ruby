# frozen_string_literal: true

require_relative "literal_scan"

module Expect
  # 驱动一次单会话或多会话匹配，管理模式优先级、EOF 和共享期限，不接管 IO 所有权。
  # 调度只在扫描、回调和 IO 操作之间检查期限，不强行中断用户代码或单次正则计算。
  # @api private
  class Matcher
    # 固定本次参与的会话及初始期限；已处理 EOF 的会话仅从本次等待中移除。
    def initialize(patterns, timeout, deadline: nil, consume: true, reset_timeout_on_read: false,
                   match_by_position: false, search_window: nil)
      @patterns = patterns.finalize!
      @sessions = patterns.sessions
      @groups = patterns.text_groups
      @consume = consume
      @match_by_position = match_by_position
      @search_window = search_window
      @reset_timeout_on_read = reset_timeout_on_read
      @timeout = Expect.duration(timeout)
      # 相对期限可因接收或 continue 重算，总期限始终固定；两者共用单调时钟。
      @hard_deadline = deadline
      @deadline = next_deadline
      # 按声明顺序维护仍参与本轮等待的来源；EOF 删除后不再从完整列表重复跳过已处理项。
      @active_sessions = @sessions.each_with_object({}.compare_by_identity) { |session, active| active[session] = true }
      @stalled_matches = {}.compare_by_identity
      @polled = false
      @expired_eof_continuation = false
    end

    # 运行匹配状态机；内部 :retry 表示继续循环，最终返回一个 Result。
    def run
      @relay_buffers = {}.compare_by_identity
      prepare_sessions
      loop do
        # 先消费已缓冲的匹配，再处理 EOF，最后读取；避免进程退出时丢失最后一个匹配。
        result = if !@expired_eof_continuation && !hard_expired? && (matched = find_match)
                   handle_match(*matched)
                 elsif (session = unhandled_eof)
                   handle_eof(session)
                 elsif @expired_eof_continuation || hard_expired?
                   handle_timeout
                 else
                   read_next
                 end
        return result unless result == :retry
      end
    ensure
      restore_relay_buffers
    end

    private

    # 转义回调中的匹配临时接管预读尾部；缓冲登记和移交是一个不可拆开的状态变更。
    # 仅内部所有权操作延迟异步取消，扫描、IO、日志及用户回调仍可立即中断。
    def prepare_sessions
      @sessions.each do |session|
        if (buffer = session.interaction_buffer)
          Thread.handle_interrupt(Object => :never) do
            @relay_buffers[session] = buffer
            session.interaction_buffer = nil
            session.restore_relay_buffer(buffer)
            buffer.clear
          end
        end
        session.reset_result
      end
    end

    # 先归还所有借用来源再交付新的取消；返回尾部与恢复原缓冲对象不能被中断拆开。
    def restore_relay_buffers
      return if @relay_buffers.empty?

      Thread.handle_interrupt(Object => :never) do
        @relay_buffers.each do |session, buffer|
          buffer.replace(session.take_buffer)
          session.interaction_buffer = buffer
        end
      end
    end

    # 普通等待按声明组、会话、模式选择；单会话自动应答选最早字节位置，同位置保留声明顺序。
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- 声明优先级与单轮缓冲须在同一次扫描保持一致。
    def find_match
      # 编译后的组内来源已按身份去重；借用仅活在本次无回调扫描，不跨越 IO 或用户回调。
      groups = @groups
      buffers = {}.compare_by_identity if groups.size > 1
      earliest = nil
      groups.each do |sessions, patterns|
        sessions.each do |session|
          next unless @active_sessions.key?(session)

          buffer = buffers ? (buffers[session] ||= session.scan_buffer) : session.scan_buffer
          stalled = @stalled_matches[session]
          if stalled && (stalled[:received_bytes] != session.received_bytes || stalled[:buffer] != buffer)
            @stalled_matches.delete(session)
            stalled = nil
          end
          patterns.each do |pattern|
            return nil if hard_expired?
            next if stalled && stalled[:patterns].key?(pattern)

            position = if @search_window
                         pattern.locate(buffer, final: session.eof?, search_window: @search_window)
                       elsif pattern.value.is_a?(String)
                         locate_literal(session, pattern, buffer)
                       else
                         pattern.locate(buffer, final: session.eof?)
                       end
            # 正则本身不可由 IO 期限中断；恢复控制后也不能消费已过总期限的匹配。
            return nil if hard_expired?
            next unless position

            # 字节 0 已是最早位置，同位置仍由先声明者胜出；不再执行无法胜出的规则。
            return [session, pattern, position] if !@match_by_position || position.first.zero?

            earliest = [session, pattern, position] if !earliest || position.first < earliest.last.first
          end
        end
      end
      earliest
    end

    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # 仅复用同一缓冲代次中的字面未命中。保留模式长度减一的重叠区，覆盖跨读取命中。
    # 不保存整个文本，也不对正则推断扫描窗口；回调替换、消费或转接恢复会改变代次。
    def locate_literal(session, pattern, buffer)
      @literal_scans ||= {}.compare_by_identity
      scan = (@literal_scans[session] ||= LiteralScan.new)
      offset = scan.index(buffer, pattern.value, generation: session.buffer_generation)
      [offset, pattern.value.bytesize, []] if offset
    end

    # 先记录并消费匹配，再执行回调；回调可选择结束、重置期限或保留期限继续。
    def handle_match(session, pattern, position)
      # 没有回调的终止匹配不可能继续，无须复制完整缓冲建立防空转快照。
      previous_buffer = session.buffer if pattern.callback
      received_bytes = session.received_bytes
      result = session.record_match(pattern, position, consume: @consume)
      action = pattern.call(session)
      return result unless continuing?(action)

      # 同值赋回仍须防止空转；嵌套读取到的新字节即使内容相同，也能恢复匹配。
      if session.received_bytes == received_bytes && session.scan_buffer == previous_buffer
        # 声明模式各有独立身份；恒定成本查询，避免重复继续时遍历不断增长的停滞数组。
        stalled = (@stalled_matches[session] ||= {
          buffer: previous_buffer, received_bytes:, patterns: {}.compare_by_identity
        })
        stalled[:patterns][pattern] = true
      end
      @deadline = next_deadline if CONTINUE.equal?(action)
      # 总期限到达时回主循环先派发已知 EOF；仅相对期限延续原有立即超时语义。
      return handle_timeout if CONTINUE_WITHOUT_RESET.equal?(action) && expired? && !hard_expired?

      :retry
    end

    # 找出尚未派发 EOF 事件的会话，保证每个源只处理一次结束事件。
    def unhandled_eof
      @active_sessions.each_key.find(&:eof?)
    end

    # 将剩余字节交给 EOF 回调；需要继续时等待其他源，全部结束则立即返回。
    def handle_eof(session)
      result = session.record_eof
      @active_sessions.delete(session)
      actions = @patterns.eof_patterns_for(session).map { |pattern| pattern.call(session) }
      return result unless actions.any? { |action| continuing?(action) }

      reset_timeout = actions.any? { |action| CONTINUE.equal?(action) }
      @deadline = next_deadline if reset_timeout
      return result if @active_sessions.empty?

      # 期限已过时不再扫描文本，但先派发已知 EOF；最后一个源结束不能被误报为超时。
      @expired_eof_continuation = !reset_timeout && expired?

      :retry
    end

    # 在剩余期限内等待可读 IO；零超时仍允许首次非阻塞轮询，EINTR 重试不重新计时。
    def read_next
      return handle_timeout if hard_expired? || (@polled && expired?)

      readers = active_sessions
      begin
        # 先标记已轮询；即使 select 连续被信号中断，下一轮也会检查原期限。
        @polled = true
        ready = IO.select(readers.map(&:to_io).uniq(&:object_id), nil, nil, remaining)
      rescue Errno::EINTR
        return :retry
      rescue IOError, SystemCallError => error
        return record_error(error)
      end
      return handle_timeout unless ready

      read_ready(ready.first, readers)
    end

    # 每个就绪 IO 读取一次，将异常归属到对应会话；仅显式启用时按接收数据刷新期限。
    def read_ready(readable, sessions)
      # select 返回 IO 对象本身；共享同一 IO 时仍选择声明顺序中的首个会话。
      if readable.size > 1
        by_io = {}.compare_by_identity
        sessions.each { |session| by_io[session.to_io] ||= session }
      end
      readable.each do |io|
        break if hard_expired?

        session = by_io ? by_io.fetch(io) : sessions.find { |candidate| candidate.to_io.equal?(io) }
        begin
          # 转接回调消费匹配内容，余下字节交回 Relay，不能在这里提前转发两次。
          data = session.read_available(propagate: !@relay_buffers.key?(session))
        rescue Errno::EINTR
          next
        rescue IOError, SystemCallError => error
          return session.record_error(error)
        end
        @stalled_matches.delete(session) if data
        @deadline = next_deadline if data && @reset_timeout_on_read
      end
      :retry
    end

    # 返回本次仍需监听的会话，供读取选择和超时回调使用。
    def active_sessions = @active_sessions.keys

    # 只有约定的继续符号会驱动下一轮，普通回调返回值不会改变等待流程。
    def continuing?(action) = CONTINUE.equal?(action) || CONTINUE_WITHOUT_RESET.equal?(action)

    # 使用单调时钟计算期限；nil 一直表示无限等待，不受系统时间调整影响。
    # 每次重置都重新与总期限取较早者，避免连续输入或继续回调无限推迟结束。
    def next_deadline
      relative = @timeout && (Expect.monotonic + @timeout)
      return @hard_deadline unless relative
      return relative unless @hard_deadline

      [relative, @hard_deadline].min
    end

    # 计算传给 select 的非负等待秒数，避免计时跨过边界时产生负数。
    def remaining = @deadline && [@deadline - Expect.monotonic, 0].max

    # 判断有限期限是否已到达；无限等待不会触发超时。
    def expired? = !@deadline.nil? && Expect.monotonic >= @deadline

    # 绝对总期限不受接收数据和 continue 重置；已知 EOF 仍按原顺序派发。
    def hard_expired? = !@hard_deadline.nil? && Expect.monotonic >= @hard_deadline

    # select 失败时无法归属单个源，只更新仍监听的会话；已派发 EOF 的结果保持不变。
    def record_error(error)
      active_sessions.map { |session| session.record_error(error) }.first
    end

    # 为活跃会话记录超时，回调接收全部活跃源；只有重置计时的继续符号能重新等待。
    # 已到总期限仍通知超时回调，但不接受继续请求，且不消费尚未匹配的字节。
    def handle_timeout
      results = active_sessions.map(&:record_timeout)
      action = @patterns.timeout_pattern&.call(active_sessions)
      return results.first unless CONTINUE.equal?(action) && !hard_expired?

      @deadline = next_deadline
      @polled = false
      @expired_eof_continuation = false
      :retry
    end
  end
  private_constant :Matcher
end
