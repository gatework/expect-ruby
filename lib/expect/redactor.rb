# frozen_string_literal: true

class Expect
  # 单个日志字节流的过滤器。保留最长秘密长度减一的尾部，跨 write/read 分片仍可识别。
  # 掩码与原字节一起留存；重叠命中的区间取并集，已经输出的掩码不重复生成。
  # 上层负责传入已复制的非空二进制秘密，每个日志目标或诊断方向使用独立实例。
  class Redactor
    # pending 保存尚不能安全输出的原字节，hidden 的对应字节用 0/1 表示是否需要遮盖。
    def initialize(patterns)
      self.patterns = patterns
      @pending = "".b
      @hidden = "".b
      @masking = false
    end

    # 更新后续匹配规则并保留已有尾部与掩码；不能追溯修改已经交付给日志目标的内容。
    def patterns=(patterns)
      @patterns = patterns
      @lookbehind = patterns.map(&:bytesize).max - 1
    end

    # 追加一个原始字节块，返回已经可以确定的安全前缀；新秘密可能跨越此前保留的尾部。
    def append(data)
      @pending << data
      @hidden << ("\0" * data.bytesize)
      mark_secrets
      release([@pending.bytesize - @lookbehind, 0].max)
    end

    # EOF、日志目标替换及关闭是流边界；尾部疑似秘密前缀也遮盖，不能因 flush 泄露片段。
    def finish
      mark_secrets
      @patterns.each do |pattern|
        [pattern.bytesize - 1, @pending.bytesize].min.downto(1) do |length|
          next unless @pending.end_with?(pattern.byteslice(0, length))

          @hidden[-length, length] = "\1" * length
          break
        end
      end
      output = release(@pending.bytesize)
      @masking = false
      output
    end

    private

    # 每次只将命中区域标为隐藏，不清除旧掩码；偏移逐字节推进以识别相互重叠的秘密。
    def mark_secrets
      @patterns.each do |pattern|
        offset = -1
        while (offset = @pending.index(pattern, offset + 1))
          @hidden[offset, pattern.bytesize] = "\1" * pattern.bytesize
        end
      end
    end

    # 按连续区间输出，避免逐字节构造字符串；只保存尚可能与下一块组成秘密的后缀。
    # masking 跨 append 保留，使被分成多个块的同一隐藏区间只输出一次 [FILTERED]。
    def release(length)
      output = "".b
      cursor = 0
      while cursor < length
        hidden = @hidden.getbyte(cursor) == 1
        ending = [@hidden.index(hidden ? "\0" : "\1", cursor) || length, length].min
        if hidden
          output << "[FILTERED]" unless @masking
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

  private_constant :Redactor
end
