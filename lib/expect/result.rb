# frozen_string_literal: true

module Expect
  # 一次等待的不可变快照；session 与 error 只引用来源和原始异常，不取得其所有权。
  # 文本和捕获值单独复制冻结，后续读取或调用者修改输入不会改变结果。
  # @!method self.new(**fields)
  #   按字段关键字或成员顺序的位置参数构造不可变结果。
  # @!method self.[](**fields)
  #   使用与 new 相同的参数构造不可变结果。
  # @!method self.members
  #   返回按声明顺序排列的字段名。
  # @!method self.inspect
  #   返回结果类的说明。
  # @!method members
  #   返回按声明顺序排列的字段名。
  # @!method with(**fields)
  #   复制结果并替换指定字段，新文本仍独立冻结。
  # @!method to_h
  #   返回字段 Hash；有块时按 Ruby Data 协议转换键值对。
  # @!method deconstruct
  #   按成员声明顺序返回字段数组。
  # @!method deconstruct_keys(keys)
  #   按指定键解构结果，nil 表示全部字段。
  Result = Data.define(:status, :match_number, :error, :match, :before, :after, :session, :captures) do
    # 构造独立不可变快照，复制字符串和捕获数组。
    # @param captures [Array<String, nil>] 按声明顺序保存捕获组，未参与的组保留 nil。
    def initialize(status:, match_number: nil, error: nil, match: nil, before: nil, after: nil,
                   session: nil, captures: [])
      raise ArgumentError, "captures must be an Array" unless captures.is_a?(Array)

      validate_outcome!(status, match_number, error, match, after, captures)
      super(status:, match_number:, error:, session:, match: copy_text(match), before: copy_text(before),
            after: copy_text(after), captures: captures.map { |value| copy_text(value) }.freeze)
    end

    # 诊断只显示匹配序号和错误状态，不检查原始文本、异常或来源对象。
    # @return [String] 不包含协议内容的结果摘要。
    def inspect = "#<#{self.class} status=#{status} match_number=#{match_number.inspect}>"

    # Data 的默认 to_s 独立于 inspect；字符串插值同样只使用安全摘要。
    # @return [String] 与 inspect 相同的结果摘要。
    def to_s = inspect

    # 是否命中文本；EOF 和超时没有模式序号。
    def matched? = status == :matched

    # 是否因等待期限到达而返回。
    def timeout? = status == :timeout

    # 是否读取源已经结束，子进程状态由会话单独查询。
    def eof? = status == :eof

    # 是否因原始 IO 异常结束；等待事件不属于异常。
    def error? = status == :error

    private

    # 正文和捕获使用同一快照边界；不转换任意对象，也不冻结调用方的字符串。
    def copy_text(value)
      return nil if value.nil?

      raise ArgumentError, "result text must be a String or nil" unless value.is_a?(String)

      value.dup.freeze
    end

    # 状态是唯一判据；new、[] 和 with 都经过同一边界，不能产生相互矛盾的结果。
    def validate_outcome!(status, match_number, error, match, after, captures)
      valid = case status
              when :matched
                match_number.is_a?(Integer) && match_number.positive? && match.is_a?(String) && error.nil?
              when :eof, :timeout, :error
                match_number.nil? && match.nil? && after.nil? && captures.empty? &&
                (status == :error ? error.is_a?(Exception) : error.nil?)
              else false
              end
      raise ArgumentError, "inconsistent result status and fields" unless valid
    end
  end
end
