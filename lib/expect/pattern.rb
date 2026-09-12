# frozen_string_literal: true

class Expect
  # 一个已编号的文本模式或事件及其回调；匹配结果统一使用字节偏移，便于精确消费 IO 缓冲。
  Pattern = Struct.new(:number, :value, :callback, keyword_init: true) do
    # 将匹配会话或超时会话数组交给回调；额外上下文由调用方闭包保存。
    def call(subject)
      callback&.call(subject)
    end

    # 识别 EOF 事件，供引擎在源结束时单独派发。
    def eof? = value == :eof

    # 在缓冲中定位字符串或正则，返回 [字节偏移, 字节长度, 捕获组]；事件或未匹配返回 nil。
    def locate(buffer)
      case value
      when String
        offset = buffer.index(value)
        return [offset, value.bytesize, []] if offset
      when Regexp
        text = buffer.dup
        text.force_encoding(value.encoding) if value.fixed_encoding?
        unless text.valid_encoding?
          # 一次读取可能截断 UTF-8 字符。仅对完整前缀做本轮匹配，原缓冲保留残片等待后续字节。
          text = complete_prefix(text)
        end
        found = value.match(text)
        return unless found

        # Ruby 正则偏移按字符计算，缓冲切片按字节计算，必须转换；捕获组也统一返回字节串。
        offset = text[0...found.begin(0)].bytesize
        return [offset, found[0].bytesize, found.captures.map { |capture| capture&.b }]
      end
      nil
    end

    private

    # 仅容忍末尾尚未收全的 UTF-8 字符，其他非法编码直接报错，不静默替换接收字节。
    def complete_prefix(text)
      if text.encoding == Encoding::UTF_8
        # UTF-8 字符最多四字节，不完整后缀最多三字节。逐一验证头字节、续字节及剩余前缀。
        1.upto([3, text.bytesize].min) do |length|
          prefix = text.byteslice(0, text.bytesize - length)
          suffix = text.byteslice(text.bytesize - length, length).b
          lead = suffix.getbyte(0)
          expected = case lead
                     when 0xC2..0xDF then 2
                     when 0xE0..0xEF then 3
                     when 0xF0..0xF4 then 4
                     end
          if expected && length < expected && suffix.bytes.drop(1).all? do |byte|
            (0x80..0xBF).cover?(byte)
          end && prefix.valid_encoding?
            return prefix
          end
        end
      end
      raise EncodingError, "received invalid #{text.encoding} data; use a binary regexp (/.../n) for binary streams"
    end
  end
end
