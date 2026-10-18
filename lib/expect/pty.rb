# frozen_string_literal: true

require "pty"
require "json"
require "io/console"
require "stringio"
require_relative "version"
require_relative "result"
require_relative "resource_owner"
require_relative "pattern"
require_relative "pattern_list"
require_relative "matcher"
require_relative "cleanup"
require_relative "child_process"
require_relative "session"
require_relative "session_factory"
require_relative "responder"

# PTY 会话的创建、匹配与转接入口；可变状态只属于返回的 Session。
module Expect
  # 重置相对期限后继续等待。
  CONTINUE = :continue
  # 保留原相对期限继续等待。
  CONTINUE_WITHOUT_RESET = :continue_without_reset
  # 单轮非阻塞读写的最大字节数。
  # @api private
  READ_SIZE = 16_384
  private_constant :READ_SIZE

  # PTY 创建后命令启动失败。
  class SpawnError < StandardError
    # 子进程报告的系统错误编号；非系统启动错误为 nil。
    attr_reader :errno

    # 保持启动异常类型，并携带可用于诊断的系统错误编号。
    def initialize(message = "process spawn failed", errno: nil)
      @errno = errno
      super(message)
    end
  end

  # 未知子进程异常仅保留描述，不根据外部类名恢复对象。
  # @api private
  class ChildFailure < StandardError; end
  private_constant :ChildFailure

  # 拒绝同源递归转接及接收交付回调中的同源递归读取，防止数据归属和顺序被破坏。
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
    def spawn(*command, env: {}, chdir: nil, raw: false, shell: false, graceful: false,
              timeout: nil, write_timeout: nil, buffer_limit: nil, logger: nil, transcript: nil, outputs: [])
      session = nil
      spawned = false
      cleanup = lambda do
        if session && (block_given? || !spawned)
          session.cleanup_session(nil, writer: nil, own: false, graceful: spawned && graceful)
        end
      end
      Cleanup.always(cleanup) do
        # 工厂在构造期间处理失败；成功对象的返回与登记不可被中断拆开。
        Thread.handle_interrupt(Object => :never) do
          session = SessionFactory.pty(timeout:, write_timeout:, buffer_limit:, logger:, transcript:, outputs:)
        end
        session.spawn(*command, env:, chdir:, raw:, shell:)
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
      constructing = false
      cleanup = lambda do
        if session && (block_given? || !initialized)
          session.cleanup_session(io, writer:, own:, graceful: initialized && graceful)
        elsif !session && own && !constructing
          ResourceOwner.close_handles(io, writer)
        end
      end
      Cleanup.always(cleanup) do
        Thread.handle_interrupt(Object => :never) do
          constructing = true
          session = SessionFactory.io(io, writer:, own:, timeout:, write_timeout:, buffer_limit:,
                                          logger:, transcript:, outputs:)
        end
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
    def expect(*patterns, from: [], timeout: nil, deadline: nil, consume: true, reset_timeout_on_read: false,
               search_window: nil, &)
      run_expect(from, patterns, timeout, deadline:, consume:, reset_timeout_on_read:, search_window:, &)
    end

    # 返回回调继续控制符，reset_timeout 为 false 时保留原相对期限。
    def continue(reset_timeout: true) = reset_timeout ? CONTINUE : CONTINUE_WITHOUT_RESET

    # 当前单调时钟秒数；供跨多次等待共享 deadline。
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # 转换有限非负秒数，nil 表示无相对期限。
    def duration(value)
      return nil if value.nil?

      number = numeric_seconds(value)
      raise ArgumentError, "duration must be finite and nonnegative" unless number >= 0

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

    # 数值协议统一拒绝非实数和非有限值；不宽松解析字符串或布尔值。
    def numeric_seconds(value)
      raise ArgumentError, "seconds must be a real Numeric" unless value.is_a?(Numeric) && !value.is_a?(Complex)

      number = Float(value)
      raise ArgumentError, "seconds must be finite" unless number.finite?

      number
    rescue TypeError, RangeError
      raise ArgumentError, "seconds must be a finite real Numeric"
    end

    # 按对象身份归属就绪描述符，不能用 IO 的值相等规则合并来源。
    def select_ready_sessions(sessions, readable)
      by_io = readable.each_with_object({}.compare_by_identity) { |io, index| index[io] = true }
      sessions.select { |session| by_io.key?(session.to_io) }
    end

    # 声明完成后固定模式；有参数块保留调用方 self，无参数块使用模式 DSL。
    def run_expect(sessions, patterns, timeout, deadline:, consume:, reset_timeout_on_read:,
                   match_by_position: false, search_window: nil, &block)
      unless search_window.nil? || (search_window.is_a?(Integer) && search_window.positive?)
        raise ArgumentError, "search_window must be a positive Integer or nil"
      end

      timeout = duration(timeout)
      deadline = numeric_seconds(deadline) unless deadline.nil?
      raise ArgumentError, "provide patterns or a pattern block, not both" if block_given? && !patterns.empty?

      pattern_list = PatternList.new(sessions, patterns)
      if block
        block.parameters.empty? ? pattern_list.instance_exec(&block) : block.call(pattern_list)
      end
      Matcher.new(pattern_list, timeout, deadline:, consume:, reset_timeout_on_read:, match_by_position:,
                                         search_window:).run
    end
  end
end
