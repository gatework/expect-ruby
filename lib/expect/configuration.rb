# frozen_string_literal: true

class Expect
  # 集中校验会话配置。类级默认值以冻结快照发布，每个会话再构造独立副本。
  # 这里只保存策略值，不持有 IO、缓冲或日志对象；修改默认配置不会追溯影响已创建的会话。
  class Configuration
    # 各配置项的初始值；会话仅保存经 setter 验证后的副本。
    DEFAULTS = {
      timeout: nil, write_timeout: nil, buffer_limit: nil, debug_level: 0,
      raw_pty: false, preserve_buffer: false, log_stdout: false,
      log_listeners: true, raw_terminal: true, reset_timeout_on_read: false,
      graceful_close: false
    }.freeze
    # 属性委托和快照导出使用同一配置清单。
    ATTRIBUTES = DEFAULTS.keys.freeze
    # 配置键与读取接口分开：布尔值只提供谓词，导出仍使用原配置键。
    READERS = DEFAULTS.to_h do |name, value|
      [name, [true, false].include?(value) ? :"#{name}?" : name]
    end.freeze

    attr_reader :timeout, :write_timeout, :buffer_limit, :debug_level

    # 布尔读写遵循 Ruby 真值规则，仅提供问号查询和 setter。
    def self.boolean_attribute(name)
      define_method(:"#{name}?") { instance_variable_get(:"@#{name}") }

      define_method(:"#{name}=") { |value| instance_variable_set(:"@#{name}", !!value) }
    end
    private_class_method :boolean_attribute

    # 先拒绝未知键，再经 setter 校验；发布中的冻结快照不会被部分修改。
    def initialize(**options)
      unknown = options.keys - ATTRIBUTES
      raise ArgumentError, "unknown configuration: #{unknown.join(", ")}" unless unknown.empty?

      DEFAULTS.merge(options).each { |name, value| public_send(:"#{name}=", value) }
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
    # @!method raw_pty?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method raw_pty=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :raw_pty

    # 控制匹配成功后是否保留完整缓冲；启用时由继续回调自行消费匹配内容。
    # @!method preserve_buffer?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method preserve_buffer=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :preserve_buffer

    # 控制接收字节是否同步输出到当前 $stdout；默认关闭。
    # @!method log_stdout?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method log_stdout=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :log_stdout

    # 控制接收字节是否转发给监听器，与 stdout 和日志目标分别管理。
    # @!method log_listeners?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method log_listeners=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :log_listeners

    # 控制 interact 是否临时设置并恢复本地输入终端；通用 interconnect 不修改终端模式。
    # @!method raw_terminal?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method raw_terminal=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :raw_terminal

    # 控制收到任何新数据时是否刷新匹配期限，适用于按静默时长判断超时。
    # 只刷新相对 timeout；单次等待显式指定的绝对 deadline 仍是不可延长的上限。
    # @!method reset_timeout_on_read?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method reset_timeout_on_read=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :reset_timeout_on_read

    # 控制通用 close 是否先软关闭；最终资源清理仍由硬关闭兜底。
    # @!method graceful_close?
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @return [Boolean] 当前布尔配置。
    # @!method graceful_close=(value)
    #   查询或设置此会话策略，使用 Ruby 真值规则。
    #   @param value [Object] 除 nil/false 外均转换为 true。
    #   @return [Boolean] 归一化的布尔配置。
    boolean_attribute :graceful_close

    # 导出新的属性 Hash，用于构造会话副本或发布下一份默认配置。
    def to_h
      READERS.to_h { |name, reader| [name, public_send(reader)] }
    end
  end
end
