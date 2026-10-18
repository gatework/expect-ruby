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
  Result = Data.define(:number, :error, :match, :before, :after, :session, :captures) do
    # 构造独立不可变快照，复制字符串和捕获数组。
    # @param captures [Array<String, nil>] 按声明顺序保存捕获组，未参与的组保留 nil。
    def initialize(number: nil, error: nil, match: nil, before: nil, after: nil, session: nil, captures: [])
      super(number:, error:, session:, match: match&.dup&.freeze,
            before: before&.dup&.freeze, after: after&.dup&.freeze,
            captures: captures.map { |value| value&.dup&.freeze }.freeze)
    end

    # 诊断只显示匹配序号和错误状态，不检查原始文本、异常或来源对象。
    # @return [String] 不包含协议内容的结果摘要。
    def inspect
      state = if error.nil? then "none"
              elsif error.equal?(:eof) then "eof"
              elsif error.equal?(:timeout) then "timeout"
              else "exception"
              end
      index = number.is_a?(Integer) ? number.to_s : "nil"
      "#<#{self.class} number=#{index} error=#{state}>"
    end

    # Data 的默认 to_s 独立于 inspect；字符串插值同样只使用安全摘要。
    # @return [String] 与 inspect 相同的结果摘要。
    def to_s = inspect

    # 是否命中文本；EOF 和超时没有模式序号。
    def matched? = !number.nil?

    # 是否因等待期限到达而返回。
    def timeout? = error == :timeout

    # 是否读取源已经结束，子进程状态由会话单独查询。
    def eof? = error == :eof
  end
end
