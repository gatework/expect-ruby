# frozen_string_literal: true

require_relative "test_helper"

class PatternOffsetTest < ExpectTest
  def test_byte_offsets_captures_and_buffer_consumption
    cases = [
      ["abENDtail", /END/, 2, 3, []],
      ["中文终点尾", /(终)(点)/, 6, 6, ["终".b, "点".b]],
      ["😀中😀尾", /(😀)(x)?/, 0, 4, ["😀".b, nil]],
      ["😀中END尾", /END/, 7, 3, []],
      ["a\0b", /(\0)/n, 1, 1, ["\0".b]],
      ["\xFF\x00\xFE".b, /(\xFE)/n, 2, 1, ["\xFE".b]],
      ["中文尾", /(?=尾)/, 6, 0, []],
      ["😀", /$/u, 4, 0, []]
    ]
    session, = pipe_session
    cases.each do |text, regexp, offset, length, captures|
      # 扫描只读调用者输入；省去正则副本后也不能改变编码标记或冻结字符串。
      bytes = text.b.freeze
      assert_equal [offset, length, captures], Expect.const_get(:Pattern).new(value: regexp).locate(bytes)
      assert_equal Encoding::BINARY, bytes.encoding
      session.buffer = bytes
      result = session.expect(regexp, timeout: 0)
      assert_equal bytes.byteslice(0, offset), result.before
      assert_equal bytes.byteslice(offset, length), result.match
      assert_equal bytes.byteslice((offset + length)..), result.after
      assert_equal captures, result.captures
      assert_equal result.after, session.buffer
    end
  end

  def test_incomplete_utf8_defers_matching_and_eof_still_rejects_it
    pattern = Expect.const_get(:Pattern).new(value: /中(?=😀)/)
    bytes = "前中😀".b
    (1..3).each do |missing|
      partial = bytes.byteslice(0, bytes.bytesize - missing)
      assert_nil pattern.locate(partial)
      assert_raises(EncodingError) { pattern.locate(partial, final: true) }
    end
    assert_equal [3, 3, []], pattern.locate(bytes)
  end
end
