# frozen_string_literal: true

require_relative "literal_prefix"

module Expect
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
      @scanned_bytes = 0
    end

    # 追加一个原始字节块，返回已经可以确定的安全前缀；新秘密可能跨越此前保留的尾部。
    def append(data)
      append_chunk(data, visible: true)
    end

    # 诊断级别关闭时仍推进连续匹配，禁止本块和它延迟到以后释放的字节进入日志。
    # 输出资格只用于内部诊断；独立过滤器的 append / finish 契约不变。
    # @api private
    def suppress(data)
      append_chunk(data, visible: false)
      nil
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

    # 输出资格与秘密掩码分开保存；仅遇到被抑制的分片时才分配额外字节图。
    def append_chunk(data, visible:)
      raise ArgumentError, "data must be a String" unless data.is_a?(String)

      @suppressed ||= "\0" * @pending.bytesize unless visible
      @suppressed << ((visible ? "\0" : "\1") * data.bytesize) if @suppressed
      @pending << data.b
      @hidden << ("\0" * data.bytesize)
      mark_secrets
      release([@pending.bytesize - @lookbehind, 0].max)
    end

    # 流关闭时无法再等待后续字节，默认隐藏与秘密开头一致的未完成尾部。
    def mark_partial_secrets
      return if @pending.empty?

      @patterns.each do |pattern|
        length = LiteralPrefix.length(@pending, pattern)
        next unless length.positive?

        @hidden[-length, length] = "\1" * length
      end
    end

    # 每个模式只扫描可能跨越新增字节的起点；规则更新后从头重扫保留窗口。
    # 重叠命中取并集，同一模式的相交/相邻区间只写一次，不清除旧掩码。
    def mark_secrets
      size = @pending.bytesize
      return if @scanned_bytes == size

      @patterns.each do |pattern|
        length = pattern.bytesize
        offset = @scanned_bytes >= length ? @scanned_bytes - length + 1 : 0
        starting = @pending.index(pattern, offset)
        next unless starting

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
      @scanned_bytes = size
    end

    # 按连续区间输出，避免逐字节构造字符串；只保存尚可能与下一块组成秘密的后缀。
    # masking 跨 append 保留，使被分成多个块的同一隐藏区间只输出一次替换标记。
    def release(length)
      output = "".b
      return output if length.zero?

      cursor = 0
      while cursor < length
        hidden = @hidden.getbyte(cursor) == 1
        ending = [@hidden.index(hidden ? "\0" : "\1", cursor) || length, length].min
        if @suppressed
          release_suppressed(output, cursor, ending, hidden:)
        else
          if hidden
            output << @replacement unless @masking
          else
            output << @pending.byteslice(cursor, ending - cursor)
          end
          @masking = hidden
        end
        cursor = ending
      end
      remaining = @pending.bytesize - length
      @pending = @pending.byteslice(length, remaining)
      @hidden = @hidden.byteslice(length, remaining)
      @suppressed = @suppressed.byteslice(length, remaining) if @suppressed
      @scanned_bytes = remaining
      output
    end

    # 仅级别切换后的流需要按输出资格再分段，普通过滤不承担额外区间调用。
    def release_suppressed(output, starting, ending, hidden:)
      while starting < ending
        suppressed = @suppressed.getbyte(starting) == 1
        boundary = [@suppressed.index(suppressed ? "\0" : "\1", starting) || ending, ending].min
        if suppressed
          @masking = false unless hidden
        else
          if hidden
            output << @replacement unless @masking
          else
            output << @pending.byteslice(starting, boundary - starting)
          end
          @masking = hidden
        end
        starting = boundary
      end
    end
  end
end
