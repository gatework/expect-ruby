# frozen_string_literal: true

require "pty"
require "io/console"
require "stringio"
require_relative "expect/version"
require_relative "expect/result"
require_relative "expect/session_resources"
require_relative "expect/pattern"
require_relative "expect/pattern_list"
require_relative "expect/matcher"
require_relative "expect/cleanup"
require_relative "expect/session"

# PTY 会话的创建、匹配与转接入口；可变状态只属于返回的 Session。
module Expect
  # 重置相对期限后继续等待。
  CONTINUE = :continue
  # 保留原相对期限继续等待。
  CONTINUE_WITHOUT_RESET = :continue_without_reset
  # 单轮非阻塞读写的最大字节数。
  # @api private
  READ_SIZE = 16_384

  # PTY 创建后命令启动失败。
  class SpawnError < StandardError; end
  # 同一个来源不能同时交给两个 Relay。
  class ReentrancyError < StandardError; end

  # 本次写入已经确认交付的进度；其他嵌套写入的异常保留在 cause。
  class WriteTimeout < IOError
    # 本次 write 已被底层接受的字节数。
    attr_reader :bytes_written

    # 构造包含已交付字节数的背压超时。
    def initialize(message = "write timed out", bytes_written: 0)
      @bytes_written = bytes_written
      super(message)
    end
  end

  class << self
    # 创建并启动 Session；有块时返回块结果，并按 graceful 策略关闭所属资源。
    # raw 只控制本次子进程 PTY；日志与输出对象始终借用。
    def spawn(*command, env: {}, chdir: nil, raw: false, graceful: false,
              timeout: nil, write_timeout: nil, buffer_limit: nil, logger: nil, transcript: nil, outputs: [])
      session = nil
      spawned = false
      cleanup = -> { session&.close(graceful: spawned && graceful) if block_given? || !spawned }
      Cleanup.always(cleanup) do
        session = Session.new(timeout:, write_timeout:, buffer_limit:, logger:, transcript:, outputs:)
        session.spawn(*command, env:, chdir:, raw:)
        spawned = true
        block_given? ? yield(session) : session
      end
    end

    # 适配真实 IO；own 只决定读写端点的关闭责任，日志与输出目标仍由调用者管理。
    # 有块时返回块结果；初始化失败也清理已取得的所属端点。
    def open(io, writer: io, own: false, graceful: false,
             timeout: nil, write_timeout: nil, buffer_limit: nil, logger: nil, transcript: nil, outputs: [])
      session = nil
      initialized = false
      cleanup = lambda do
        if session && (block_given? || !initialized)
          session.cleanup_session(io, writer:, own:, graceful: initialized && graceful)
        elsif !session && own
          SessionResources.close_handles(io, writer)
        end
      end
      Cleanup.always(cleanup) do
        session = Session.allocate
        session.__send__(:initialize_io, io, writer:, own:, timeout:, write_timeout:, buffer_limit:,
                                             logger:, transcript:, outputs:)
        initialized = true
        block_given? ? yield(session) : session
      end
    end

    # 按 outputs 建立转发图，返回引发停止的 Session；总期限到达返回 nil。
    def interconnect(*sessions, timeout: nil)
      raise ArgumentError, "interconnect requires Session objects" unless sessions.any? && sessions.all?(Session)

      Relay.new(sessions, timeout).run
    end

    # 共同等待指定来源，返回不可变 Result。consume 控制本轮是否消费匹配文本。
    # reset_timeout_on_read 仅重置相对期限，deadline 始终是不可延长的总期限。
    def expect(*patterns, from: [], timeout: nil, deadline: nil, consume: true, reset_timeout_on_read: false, &)
      run_expect(from, patterns, timeout, deadline:, consume:, reset_timeout_on_read:, &)
    end

    # 返回回调继续控制符，reset_timeout 为 false 时保留原相对期限。
    def continue(reset_timeout: true) = reset_timeout ? CONTINUE : CONTINUE_WITHOUT_RESET

    # 当前单调时钟秒数；供跨多次等待共享 deadline。
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # 转换有限非负秒数，nil 表示无相对期限。
    def duration(value)
      return nil if value.nil?

      number = Float(value)
      raise ArgumentError, "duration must be finite and nonnegative" unless number.finite? && number >= 0

      number
    end

    # 返回可读 Session，不消费输入；去重、排除已关闭来源，并保留声明顺序。
    def readable_sessions(*sessions, timeout: 0)
      timeout = duration(timeout)
      raise ArgumentError, "readable_sessions requires Session objects" unless sessions.all?(Session)

      active = sessions.uniq(&:object_id).reject(&:closed?)
      return [] if active.empty?

      deadline = timeout && (monotonic + timeout)
      polled = false
      ready = nil
      loop do
        remaining = deadline && [deadline - monotonic, 0].max
        return [] if polled && remaining&.zero?

        begin
          ready = IO.select(active.map(&:to_io), nil, nil, remaining)
          break
        rescue Errno::EINTR
          polled = true
        end
      end
      return [] unless ready

      select_ready_sessions(active, ready.first)
    end

    private

    # 按对象身份归属就绪描述符，不能用 IO 的值相等规则合并来源。
    def select_ready_sessions(sessions, readable)
      by_io = readable.each_with_object({}.compare_by_identity) { |io, index| index[io] = true }
      sessions.select { |session| by_io.key?(session.to_io) }
    end

    # 声明完成后固定模式；有参数块保留调用方 self，无参数块使用模式 DSL。
    def run_expect(sessions, patterns, timeout, deadline:, consume:, reset_timeout_on_read:, &block)
      timeout = duration(timeout)
      deadline = Float(deadline) unless deadline.nil?
      raise ArgumentError, "deadline must be finite" if deadline && !deadline.finite?
      raise ArgumentError, "provide patterns or a pattern block, not both" if block_given? && !patterns.empty?

      pattern_list = PatternList.new(sessions, patterns)
      if block
        block.parameters.empty? ? pattern_list.instance_exec(&block) : block.call(pattern_list)
      end
      Matcher.new(pattern_list, timeout, deadline:, consume:, reset_timeout_on_read:).run
    end
  end
end
