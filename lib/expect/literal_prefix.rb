# frozen_string_literal: true

module Expect
  # 计算字节窗口尾部与规则真前缀重合的最长长度；转义暂存和流尾脱敏使用同一边界判断。
  # 不持有输入或修改缓冲；仅长候选的扫描需要 KMP 回退表，冻结规则可跨调用缓存该表。
  # @api private
  module LiteralPrefix
    # 返回 buffer 后缀与 pattern 真前缀重合的最大字节数；真前缀不包含完整 pattern。
    # 例如 "xAB" 与 "ABC" 返回 2；空输入、长度不足 2 的规则或没有重合时返回 0。
    # 两个字符串须由调用方转为二进制编码；此处不转码、不校验，也不修改它们。
    # prefix_tables 为可选的可变 Hash；仅冻结 pattern 使用缓存，否则为本次调用建立临时表。
    def self.length(buffer, pattern, prefix_tables = nil)
      maximum = [pattern.bytesize - 1, buffer.bytesize].min
      return 0 unless maximum.positive?

      # 重合前缀的末字节必须等于输入尾字节；排除无法结束在该字节上的更长候选。
      # 最长候选直接命中时不必构造回退表；小于 64 字节的候选改用有界枚举。
      ending = pattern.rindex(buffer.byteslice(-1, 1), maximum - 1)
      return 0 unless ending

      maximum = ending + 1
      return maximum if buffer.end_with?(pattern.byteslice(0, maximum))
      return short_length(buffer, pattern, maximum - 1) if maximum < 64

      failure = prefix_tables && pattern.frozen? ? (prefix_tables[pattern] ||= []) : []
      extend_failure_table(pattern, failure, maximum)
      # 只扫描可能重合的尾部；不匹配时沿回退表保留已有重合，避免从每个候选起点重扫。
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

    # 将同一规则的可变回退表补齐到 length 项，已有项不重算，较长的缓存也不截断。
    # failure[i] 是 pattern[0..i] 的最长真前缀与后缀重合长度，供失配时选择下一匹配状态。
    # length 不超过规则的真前缀长度；表只能用于生成它的同一规则内容。
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

    # 从 maximum 向下枚举短候选，返回首个后缀重合长度，无命中时返回 0。
    # 调用方已限制候选规模；每次比较只切取规则前缀，不创建完整输入的副本或回退表。
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
