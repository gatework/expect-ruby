# frozen_string_literal: true

module Expect
  # 计算字节窗口尾部与规则真前缀重合的最长长度；转义暂存和流尾脱敏使用同一边界判断。
  # 不持有输入或修改缓冲，调用方可为冻结规则提供前缀表缓存；短规则不建立表。
  # @api private
  module LiteralPrefix
    def self.length(buffer, pattern, prefix_tables = nil)
      maximum = [pattern.bytesize - 1, buffer.bytesize].min
      return 0 unless maximum.positive?

      # 尾字节不在候选前缀内时无需扫描；最长候选本身命中时也不必构造 KMP 表。
      ending = pattern.rindex(buffer.byteslice(-1, 1), maximum - 1)
      return 0 unless ending

      maximum = ending + 1
      return maximum if buffer.end_with?(pattern.byteslice(0, maximum))
      return short_length(buffer, pattern, maximum - 1) if maximum < 64

      failure = prefix_tables && pattern.frozen? ? (prefix_tables[pattern] ||= []) : []
      extend_failure_table(pattern, failure, maximum)
      matched = 0
      index = buffer.bytesize - maximum
      while index < buffer.bytesize
        byte = buffer.getbyte(index)
        matched = failure[matched - 1] while matched.positive? && byte != pattern.getbyte(matched)
        matched += 1 if byte == pattern.getbyte(matched)
        index += 1
      end
      matched
    end

    def self.extend_failure_table(pattern, failure, length)
      failure << 0 if failure.empty?
      matched = failure.last
      index = failure.length
      while index < length
        byte = pattern.getbyte(index)
        if byte == pattern.getbyte(matched)
          matched += 1
          failure << matched
          index += 1
        elsif matched.positive?
          matched = failure[matched - 1]
        else
          failure << 0
          index += 1
        end
      end
    end

    def self.short_length(buffer, pattern, maximum)
      maximum.downto(1) do |length|
        return length if buffer.end_with?(pattern.byteslice(0, length))
      end
      0
    end

    private_class_method :extend_failure_table, :short_length
  end

  private_constant :LiteralPrefix
end
