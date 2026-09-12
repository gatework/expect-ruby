# frozen_string_literal: true

class Expect
  # 驱动一次单会话或多会话匹配，管理模式优先级、EOF 和共享期限，不接管 IO 所有权。
  class Engine
    # 固定本次参与的会话及初始期限；已处理 EOF 的会话仅从本次等待中移除。
    def initialize(patterns, timeout)
      @patterns = patterns
      @sessions = patterns.sessions
      @timeout = Expect.duration(timeout)
      @deadline = next_deadline
      @handled_eof = []
      @polled = false
    end

    # 运行匹配状态机；内部 :retry 表示继续循环，最终返回一个 Result。
    def run
      @sessions.each { |session| session.__send__(:reset_result) }
      loop do
        # 先消费已缓冲的匹配，再处理 EOF，最后读取；避免进程退出时丢失最后一个匹配。
        result = if (matched = find_match)
                   handle_match(*matched)
                 elsif (session = unhandled_eof)
                   handle_eof(session)
                 else
                   read_next
                 end
        return result unless result == :retry
      end
    end

    private

    # 按声明组、会话、模式的顺序寻找首个匹配，不按文本中的出现位置重新排序。
    def find_match
      @patterns.groups.each do |sessions, patterns|
        sessions.each do |session|
          next if @handled_eof.include?(session)

          buffer = session.buffer
          patterns.each do |pattern|
            position = pattern.locate(buffer)
            return [session, pattern, position] if position
          end
        end
      end
      nil
    end

    # 先记录并消费匹配，再执行回调；回调可选择结束、重置期限或保留期限继续。
    def handle_match(session, pattern, position)
      result = session.__send__(:record_match, pattern, position)
      action = pattern.call(session)
      return result unless continuing?(action)

      @deadline = next_deadline if action == CONTINUE
      # 零宽匹配可能不消费字节，必须在继续回调后检查期限，避免只匹配缓冲而永久空转。
      return handle_timeout if action == CONTINUE_WITHOUT_RESET && expired?

      :retry
    end

    # 找出尚未派发 EOF 事件的会话，保证每个源只处理一次结束事件。
    def unhandled_eof
      @sessions.find { |session| session.eof? && !@handled_eof.include?(session) }
    end

    # 将剩余字节交给 EOF 回调；需要继续时等待其他源，全部结束则立即返回。
    def handle_eof(session)
      result = session.__send__(:record_eof)
      @handled_eof << session
      actions = @patterns.eof_patterns_for(session).map { |pattern| pattern.call(session) }
      return result unless actions.any? { |action| continuing?(action) }

      @deadline = next_deadline if actions.include?(CONTINUE)
      @sessions.all? { |candidate| @handled_eof.include?(candidate) } ? result : :retry
    end

    # 在剩余期限内等待可读 IO；零超时仍允许首次非阻塞轮询，EINTR 重试不重新计时。
    def read_next
      return handle_timeout if @polled && expired?

      readers = active_sessions
      begin
        # 先标记已轮询；即使 select 连续被信号中断，下一轮也会检查原期限。
        @polled = true
        ready = IO.select(readers.map(&:to_io), nil, nil, remaining)
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
      readable.each do |io|
        session = sessions.find { |candidate| candidate.to_io.equal?(io) }
        begin
          data = session.__send__(:read_available)
        rescue Errno::EINTR
          next
        rescue IOError, SystemCallError => error
          return session.__send__(:record_error, error)
        end
        @deadline = next_deadline if data && session.reset_timeout_on_read?
      end
      :retry
    end

    # 返回本次仍需监听的会话，供读取选择和超时回调使用。
    def active_sessions = @sessions.reject { |session| @handled_eof.include?(session) }
    # 只有约定的继续符号会驱动下一轮，普通回调返回值不会改变等待流程。
    def continuing?(action) = [CONTINUE, CONTINUE_WITHOUT_RESET].include?(action)
    # 使用单调时钟计算期限；nil 一直表示无限等待，不受系统时间调整影响。
    def next_deadline = @timeout && (Expect.monotonic + @timeout)
    # 计算传给 select 的非负等待秒数，避免计时跨过边界时产生负数。
    def remaining = @deadline && [@deadline - Expect.monotonic, 0].max
    # 判断有限期限是否已到达；无限等待不会触发超时。
    def expired? = @deadline && Expect.monotonic >= @deadline

    # select 失败时无法归属单个源，为本次会话记录同一原始异常并返回首个结果。
    def record_error(error)
      @sessions.map { |session| session.__send__(:record_error, error) }.first
    end

    # 为活跃会话记录超时，回调接收全部活跃源；只有重置计时的继续符号能重新等待。
    def handle_timeout
      results = active_sessions.map { |session| session.__send__(:record_error, :timeout) }
      action = @patterns.timeout_pattern&.call(active_sessions)
      return results.first unless action == CONTINUE

      @deadline = next_deadline
      @polled = false
      :retry
    end
  end
end
