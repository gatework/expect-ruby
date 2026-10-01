# frozen_string_literal: true

class Expect
  # 一个已编号的文本模式或事件及其回调；匹配结果统一使用字节偏移，便于精确消费 IO 缓冲。
  # @api private
  Pattern = Data.define(:number, :value, :callback) do
    def initialize(value:, number: nil, callback: nil)
      super(value: value.is_a?(String) ? value.b.freeze : value, number:, callback:)
    end

    # 将匹配会话或超时会话数组交给回调；额外上下文由调用方闭包保存。
    def call(subject)
      callback&.call(subject)
    end

    # 识别 EOF 事件，供引擎在源结束时单独派发。
    def eof? = value == :eof

    # 在缓冲中定位字符串或正则，返回 [字节偏移, 字节长度, 捕获组]；事件或未匹配返回 nil。
    # buffer 应为二进制字符串，offset 仅用于字面扫描；正则始终看到完整窗口以保留锚点语义。
    # final 表示不会再有新输入，此时不完整的编码尾部也必须报错，不能永远当作等待分片。
    def locate(buffer, final: false, offset: 0)
      case value
      when String
        offset = buffer.index(value, offset)
        return [offset, value.bytesize, []] if offset
      when Regexp
        # 正则只读取输入；只有编码标记不同才复制，避免每个模式额外分配缓冲对象。
        text = if value.fixed_encoding? && value.encoding != buffer.encoding
                 buffer.dup.force_encoding(value.encoding)
               else
                 buffer
               end
        unless text.valid_encoding?
          # 不完整的尾字符可能改变锚点或前瞻结果，必须等字符收齐后再匹配。
          validate_incomplete_suffix!(text, final:)
          return nil
        end
        found = value.match(text)
        return unless found

        # 直接使用正则的字节范围，避免为转换字符偏移创建前缀切片；捕获组也返回字节串。
        offset, finish = found.byteoffset(0)
        return [offset, finish - offset, found.captures.map { |capture| capture&.b }]
      end
      nil
    end

    private

    # 仅容忍末尾尚未收全的 UTF-8 字符，其他非法编码直接报错，不静默替换接收字节。
    # 转码仅用于区分“不完整尾部”和“非法字节”，结果不回写缓冲，也不做编码归一化。
    def validate_incomplete_suffix!(text, final:)
      if !final && text.encoding == Encoding::UTF_8
        incomplete = begin
          text.encode(Encoding::UTF_16LE)
          false
        rescue Encoding::InvalidByteSequenceError => error
          error.incomplete_input?
        end
        return if incomplete
      end
      raise EncodingError, "received invalid #{text.encoding} data; use a binary regexp (/.../n) for binary streams"
    end
  end
  private_constant :Pattern
end
