# frozen_string_literal: true

class Expect
  # 集中校验会话配置。类级默认值以冻结快照发布，每个会话再构造独立副本。
  class Configuration
    # 会话通过 Forwardable 委托这些属性；to_h 使用同一清单生成配置副本。
    ATTRIBUTES = %i[
      timeout write_timeout buffer_limit debug_level raw_pty preserve_buffer
      log_stdout log_listeners raw_terminal reset_timeout_on_read graceful_close
    ].freeze
    # 布尔属性同时提供普通读方法和问号查询，写入统一采用 Ruby 真值规则。
    PREDICATES = %i[
      raw_pty? preserve_buffer? log_stdout? log_listeners? raw_terminal?
      reset_timeout_on_read? graceful_close?
    ].freeze

    attr_reader :timeout, :write_timeout, :buffer_limit, :debug_level, :raw_pty, :preserve_buffer, :log_stdout,
                :log_listeners, :raw_terminal, :reset_timeout_on_read, :graceful_close

    # 通过 setter 校验构造参数，确保默认值、构造覆盖和后续赋值遵守同一规则。
    def initialize(timeout: nil, write_timeout: nil, buffer_limit: nil, debug_level: 0,
                   raw_pty: false, preserve_buffer: false, log_stdout: false,
                   log_listeners: true, raw_terminal: true, reset_timeout_on_read: false,
                   graceful_close: false)
      self.timeout = timeout
      self.write_timeout = write_timeout
      self.buffer_limit = buffer_limit
      self.debug_level = debug_level
      self.raw_pty = raw_pty
      self.preserve_buffer = preserve_buffer
      self.log_stdout = log_stdout
      self.log_listeners = log_listeners
      self.raw_terminal = raw_terminal
      self.reset_timeout_on_read = reset_timeout_on_read
      self.graceful_close = graceful_close
    end

    # 设置匹配等待的默认秒数；nil 表示无限等待，0 表示只轮询现有数据。
    def timeout=(value)
      @timeout = Expect.duration(value)
    end

    # 设置写入背压的等待期限；先转换和校验，失败时保留原配置。
    def write_timeout=(value)
      @write_timeout = Expect.duration(value)
    end

    # 限制接收缓冲保留的尾部字节数；正整数为上限，nil 为无限。
    def buffer_limit=(value)
      unless value.nil? || (value.is_a?(Integer) && value.positive?)
        raise ArgumentError, "buffer_limit must be a positive Integer or nil"
      end

      @buffer_limit = value
    end

    # 设置诊断详细程度：0 关闭，1 生命周期与匹配，2 收发内容，3 缓冲内容。
    def debug_level=(value)
      unless value.is_a?(Integer) && (0..3).cover?(value)
        raise ArgumentError, "debug_level must be an Integer between 0 and 3"
      end

      @debug_level = value
    end

    # 控制 spawn 前是否将子进程终端设为 raw，关闭回显和换行转换。
    def raw_pty=(value)
      @raw_pty = !!value
    end
    alias raw_pty? raw_pty

    # 控制匹配成功后是否保留完整缓冲；启用时由继续回调自行消费匹配内容。
    def preserve_buffer=(value)
      @preserve_buffer = !!value
    end
    alias preserve_buffer? preserve_buffer

    # 控制接收字节是否同步输出到当前 $stdout；默认关闭。
    def log_stdout=(value)
      @log_stdout = !!value
    end
    alias log_stdout? log_stdout

    # 控制接收字节是否转发给监听器，与 stdout 和日志目标分别管理。
    def log_listeners=(value)
      @log_listeners = !!value
    end
    alias log_listeners? log_listeners

    # 控制人工转接期间是否自动设置并恢复终端模式。
    def raw_terminal=(value)
      @raw_terminal = !!value
    end
    alias raw_terminal? raw_terminal

    # 控制收到任何新数据时是否刷新匹配期限，适用于按静默时长判断超时。
    def reset_timeout_on_read=(value)
      @reset_timeout_on_read = !!value
    end
    alias reset_timeout_on_read? reset_timeout_on_read

    # 控制通用 close 是否先软关闭；最终资源清理仍由硬关闭兜底。
    def graceful_close=(value)
      @graceful_close = !!value
    end
    alias graceful_close? graceful_close

    # 导出新的属性 Hash，用于构造会话副本或发布下一份默认配置。
    def to_h
      ATTRIBUTES.to_h { |name| [name, public_send(name)] }
    end
  end
end
