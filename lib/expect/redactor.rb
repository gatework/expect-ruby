# frozen_string_literal: true

class Expect
  # 单个日志字节流的过滤器。保留最长秘密长度减一的尾部，跨 write/read 分片仍可识别。
  # 掩码与原字节一起留存；重叠命中的区间取并集，已经输出的掩码不重复生成。
  # 不依赖会话或 IO；每个日志目标或诊断方向使用独立实例。
  class Redactor
    # 完整诊断文本只匹配完整秘密；流边界的疑似秘密前缀由 finish 的默认策略保护。
    def self.redact(data, patterns, replacement: "[FILTERED]")
      filter = new(patterns, replacement:)
      filter.append(data) + filter.finish(partial: false)
    end

    # pending 保存尚不能安全输出的原字节，hidden 的对应字节用 0/1 表示是否需要遮盖。
    def initialize(patterns, replacement: "[FILTERED]")
      unless replacement.is_a?(String) && !replacement.empty?
        raise ArgumentError, "replacement must be a nonempty String"
      end

      @replacement = replacement.b.freeze
      self.patterns = patterns
      @pending = "".b
      @hidden = "".b
      @masking = false
    end

    # 更新后续匹配规则并保留已有尾部与掩码；不能追溯修改已经交付给日志目标的内容。
    def patterns=(patterns)
      unless patterns.is_a?(Array) && patterns.all? { |pattern| pattern.is_a?(String) && !pattern.empty? }
        raise ArgumentError, "patterns must be an Array of nonempty Strings"
      end

      @patterns = patterns.map { |pattern| pattern.b.freeze }.uniq.freeze
      @lookbehind = [(@patterns.map(&:bytesize).max || 0) - 1, 0].max
    end

    # 追加一个原始字节块，返回已经可以确定的安全前缀；新秘密可能跨越此前保留的尾部。
    def append(data)
      raise ArgumentError, "data must be a String" unless data.is_a?(String)

      @pending << data.b
      @hidden << ("\0" * data.bytesize)
      mark_secrets
      release([@pending.bytesize - @lookbehind, 0].max)
    end

    # EOF、日志目标替换及关闭是流边界；尾部疑似秘密前缀也遮盖，不能因 flush 泄露片段。
    def finish(partial: true)
      raise ArgumentError, "partial must be true or false" unless [true, false].include?(partial)

      mark_secrets
      mark_partial_secrets if partial
      output = release(@pending.bytesize)
      @masking = false
      output
    end

    # 过滤器公开后仍不在诊断摘要中展开注册秘密或尚未交付的原始字节。
    def inspect = "#<#{self.class}>"

    private

    # 流关闭时无法再等待后续字节，默认隐藏与秘密开头一致的未完成尾部。
    def mark_partial_secrets
      tail = @pending.byteslice(-1, 1)
      return unless tail

      @patterns.each do |pattern|
        length = [pattern.bytesize - 1, @pending.bytesize].min
        # 前缀必须以当前尾字节结束；只收紧最高候选长度，密集候选仍沿用简单倒序扫描。
        next unless length.positive? && (offset = pattern.rindex(tail, length - 1))

        (offset + 1).downto(1) do |candidate|
          next unless @pending.end_with?(pattern.byteslice(0, candidate))

          @hidden[-candidate, candidate] = "\1" * candidate
          break
        end
      end
    end

    # 仍逐字节推进重叠命中，但同一模式的相交/相邻区间只写一次掩码。
    # 只向旧掩码取并集，不能清除其他模式或旧规则已经隐藏的 pending 字节。
    def mark_secrets
      @patterns.each do |pattern|
        starting = @pending.index(pattern)
        next unless starting

        length = pattern.bytesize
        ending = starting + length
        offset = starting
        while (offset = @pending.index(pattern, offset + 1))
          if offset > ending
            @hidden[starting, ending - starting] = "\1" * (ending - starting)
            starting = offset
          end
          ending = offset + length
        end
        @hidden[starting, ending - starting] = "\1" * (ending - starting)
      end
    end

    # 按连续区间输出，避免逐字节构造字符串；只保存尚可能与下一块组成秘密的后缀。
    # masking 跨 append 保留，使被分成多个块的同一隐藏区间只输出一次替换标记。
    def release(length)
      output = "".b
      cursor = 0
      while cursor < length
        hidden = @hidden.getbyte(cursor) == 1
        ending = [@hidden.index(hidden ? "\0" : "\1", cursor) || length, length].min
        if hidden
          output << @replacement unless @masking
        else
          output << @pending.byteslice(cursor, ending - cursor)
        end
        @masking = hidden
        cursor = ending
      end
      @pending = @pending.byteslice(length..)
      @hidden = @hidden.byteslice(length..)
      output
    end
  end
end
