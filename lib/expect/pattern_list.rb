# frozen_string_literal: true

module Expect
  # 将 Ruby 模式和块回调整理为有序会话组；注册阶段不读取 IO、不执行匹配回调。
  # 分组结构直接决定 Matcher 的“声明组 → 会话 → 模式”优先级，不能按匹配位置重排。
  class PatternList
    # 供匹配器读取的已编译分组和超时规则。
    # @api private
    attr_reader :groups, :timeout_pattern

    # 建立默认来源，并将位置参数中的文本、正则、:eof、:timeout 转成统一模式。
    def initialize(sessions = [], patterns = [])
      @default_sessions = Array(sessions).dup
      validate_sessions!(@default_sessions) unless @default_sessions.empty?
      # 保留空模式的默认会话组，使 expect(timeout:) 也能只收集输出而不匹配文本。
      @groups = @default_sessions.empty? ? [] : [[@default_sessions, []]]
      @number = 0
      patterns.each do |value|
        case value
        when :eof then eof
        when :timeout then timeout
        else on(value)
        end
      end
    end

    # 注册文本模式；字符串始终字面匹配并复制冻结，避免注册后被外部修改。
    def on(value, from: @default_sessions, &block)
      raise ArgumentError, "pattern must be a String or Regexp" unless value.is_a?(String) || value.is_a?(Regexp)

      add(value, from, block)
    end

    # 为指定来源注册 EOF 回调；实例 DSL 默认使用当前会话。
    def eof(from: @default_sessions, &block)
      add(:eof, from, block)
    end

    # 注册一次等待的唯一超时回调，重复定义直接报错，避免悄悄覆盖业务处理。
    # 超时是整次等待的事件，回调收到全部活跃会话，不归属于某一个来源组。
    def timeout(&block)
      raise FrozenError, "patterns are finalized" if frozen?

      raise ArgumentError, "timeout callback already registered" if @timeout_pattern

      @timeout_pattern = build(:timeout, block)
      self
    end

    # 汇总并去重读取源，同一会话出现在多个模式组时仍只读取一次。
    # 这里只去重会话对象；不同会话包装同一 IO 时的读取归属由 Matcher 决定。
    # @api private
    def sessions
      groups.flat_map(&:first).each_with_object({}.compare_by_identity) do |session, unique|
        unique[session] = true
      end.keys
    end

    # 收集指定会话的所有 EOF 处理器，保留原注册顺序。
    # @api private
    def eof_patterns_for(session)
      groups.flat_map do |sessions, patterns|
        sessions.any? { |candidate| candidate.equal?(session) } ? patterns.select(&:eof?) : []
      end
    end

    # 启动引擎前确保存在读取源；类级等待必须通过 from: 明确来源。
    # @api private
    def validate!
      raise ArgumentError, "at least one session is required" if groups.empty?

      self
    end

    # 固定本次等待的规则；只冻结声明容器，不冻结借用的会话与回调。
    # @api private
    def finalize!
      validate!
      groups.each do |sessions, patterns|
        sessions.freeze
        patterns.freeze
      end
      groups.each(&:freeze).freeze
      @default_sessions.freeze
      freeze
    end

    private

    # 校验并复制来源列表，将模式加入相邻的相同来源组或新建组。
    def add(value, from, callback)
      sessions = Array(from).dup
      validate_sessions!(sessions)
      pattern = build(value, callback)
      # 仅合并相邻的相同来源，保持声明顺序；跨组复用会话由引擎去重读取。
      if same_sessions?(groups.last&.first, sessions)
        groups.last.last << pattern
      else
        groups << [sessions, [pattern]]
      end
      self
    end

    # 会话的业务相等性不能合并不同读取源；来源对象及排列都必须相同。
    def same_sessions?(previous, sessions)
      previous && previous.size == sessions.size &&
        previous.each_with_index.all? { |session, index| session.equal?(sessions[index]) }
    end

    # 按注册顺序分配从 1 开始的序号，文本模式与事件共用编号。
    def build(value, callback)
      @number += 1
      Pattern.new(number: @number, value:, callback:)
    end

    # 拒绝空来源和非 Session 对象，在任何 IO 读取之前暴露调用错误。
    def validate_sessions!(sessions)
      return if !sessions.empty? && sessions.all?(Session)

      raise ArgumentError, "patterns require Session objects; specify from: for class-level waits"
    end
  end
end
