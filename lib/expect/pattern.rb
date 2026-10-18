# frozen_string_literal: true

module Expect
  # 一个已编号的文本模式或事件及其回调；匹配结果统一使用字节偏移，便于精确消费 IO 缓冲。
  # @api private
  Pattern = Data.define(:number, :value, :callback) do
    # 复制字符串模式；Regexp 和 callable 只引用，不取得外部对象的生命周期。
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
    # captures 为 false 时只求字节范围，转义扫描不分配随后丢弃的捕获字符串。
    # final 表示不会再有新输入，此时不完整的编码尾部也必须报错，不能永远当作等待分片。
    def locate(buffer, final: false, offset: 0, captures: true, search_window: nil)
      return locate_window(buffer, search_window, final:, captures:) if search_window && buffer.bytesize > search_window

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
        return [offset, finish - offset, captures ? found.captures.map { |capture| capture&.b } : []]
      end
      nil
    end

    private

    # 只匹配显式尾部窗口内的候选，返回偏移仍属于原始缓冲；字节协议不做转码。
    def locate_window(buffer, size, final:, captures:)
      start = buffer.bytesize - size
      # 字面匹配没有锚点或回看，直接限制候选起点，复用原缓冲而不复制尾窗。
      return locate(buffer, offset: start, final:, captures:) if value.is_a?(String)

      start = utf8_window_start(buffer, start, final:) if value.is_a?(Regexp) && value.fixed_encoding? &&
                                                          value.encoding == Encoding::UTF_8
      return nil unless start

      # byteslice 会与完整缓冲共享存储，使下次追加复制整段；unpack 只复制本轮尾窗。
      position = locate(buffer.unpack1("a*", offset: start), final:, captures:)
      position[0] += start if position
      position
    end

    # 只跳过被窗口边界切开的合法 UTF-8 字符，不隐藏窗口内的非法字节。
    def utf8_window_start(buffer, start, final:)
      lead = start
      lead -= 1 while lead.positive? && start - lead < 3 && (buffer.getbyte(lead) & 0xc0) == 0x80
      first = buffer.getbyte(lead)
      width = if first.between?(0xc2, 0xdf) then 2
              elsif first.between?(0xe0, 0xef) then 3
              elsif first.between?(0xf0, 0xf4) then 4
              else 1
              end
      character = buffer.byteslice(lead, width).dup.force_encoding(Encoding::UTF_8)
      return start unless lead < start && lead + width > start
      return lead + width if character.valid_encoding?

      validate_incomplete_suffix!(character, final:)
      nil
    end

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
