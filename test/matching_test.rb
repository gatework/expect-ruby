# frozen_string_literal: true

require_relative "test_helper"

class MatchingTest < ExpectTest
  def test_literal_regexp_number_and_result_tuple
    session, = pipe_session
    session.buffer = "before a.c between abc:42 after"
    assert_equal 2, session.expect("absent", "a.c", timeout: 0)
    assert_equal "before ", session.before
    assert_equal "a.c", session.match
    result = session.expect_result(/abc:(\d+)/, timeout: 0)
    assert_equal [1, nil, "abc:42", " between ", " after", session, ["42"]], result.to_a
    assert_equal ["42"], session.captures
    assert result.matched?
    refute result.timeout?
    refute result.eof?
  end

  def test_regexp_callback_captures_lexical_arguments
    session, = pipe_session
    session.buffer = "prefix xyz42 suffix"
    observed = []
    argument = :value
    number = session.expect(timeout: 0) do
      on(/xyz(\d+)/) { |object| observed << [object.captures, argument] }
    end
    assert_equal 1, number
    assert_equal [[["42"], :value]], observed
  end

  def test_native_regexp_and_literal_event_names
    session, = pipe_session
    session.buffer = "timeout eof -word a.c end99"
    assert_equal 1, session.expect("timeout", timeout: 0)
    assert_equal 1, session.expect("eof", timeout: 0)
    assert_equal 1, session.expect("-word", timeout: 0)
    assert_equal 1, session.expect("a.c", timeout: 0)
    assert_equal 1, session.expect(/end\d+/, timeout: 0)
  end

  def test_patterns_have_priority_over_their_position_in_buffer
    session, = pipe_session
    session.buffer = "second first"
    assert_equal 1, session.expect("first", "second", timeout: 0)
    assert_equal "second ", session.before
  end

  def test_regexp_uses_actual_offset_with_lookbehind
    session, = pipe_session
    session.buffer = "same prefix same end"
    session.expect(/(?<=prefix )same/, timeout: 0)
    assert_equal "same prefix ", session.before
    assert_equal " end", session.after
  end

  def test_unmatched_capture_and_zero_width_pattern
    session, = pipe_session
    session.buffer = "b"
    assert_equal 1, session.expect(/(a)?(?=b)/, timeout: 0)
    assert_equal [nil], session.captures
    assert_equal "", session.match
    assert_equal "b", session.buffer
  end

  def test_capture_list_clears_for_literal_and_timeout
    session, = pipe_session
    session.buffer = "a1 b"
    session.expect(/a(\d)/, timeout: 0)
    session.expect("b", timeout: 0)
    assert_empty session.captures
    assert_nil session.expect(/absent/, timeout: 0)
    assert_nil session.match
    assert_nil session.after
    assert_empty session.captures
  end

  def test_buffer_retained_on_timeout_and_manually_replaceable
    session, writer = pipe_session
    writer.write("some string")
    assert_nil session.expect("other", timeout: 0.03)
    assert_equal :timeout, session.error
    assert_equal "some string", session.before
    assert_equal 1, session.expect("some", timeout: 0)
    assert_equal " string", session.buffer
    session.buffer = "new"
    assert_equal "new", session.clear_buffer
    assert_empty session.buffer
  end

  def test_preserve_buffer_and_buffer_limit
    session, = pipe_session
    session.preserve_buffer = true
    session.buffer = "prefix token tail"
    2.times { assert_equal 1, session.expect("token", timeout: 0) }
    assert_equal "prefix token tail", session.buffer
    session.buffer_limit = 4
    assert_equal "tail", session.buffer
    session.buffer_limit = nil
    session.buffer = "123456"
    assert_equal "123456", session.buffer
  end

  def test_split_patterns_across_reads
    session, writer = pipe_session
    background do
      writer.write("pass")
      sleep 0.03
      writer.write("word: ")
    end
    assert_equal 1, session.expect(/password: /, timeout: 1)
  end

  def test_utf8_regexp_split_character_and_byte_offsets
    session, writer = pipe_session
    bytes = "前缀密码：结束".b
    background do
      bytes.each_byte do |byte|
        writer.write(byte.chr)
        sleep 0.001
      end
    end
    assert_equal 1, session.expect(/(密码)：/, timeout: 1)
    assert_equal "前缀".b, session.before
    assert_equal ["密码".b], session.captures
    assert_equal 1, session.expect("结束", timeout: 1)
  end

  def test_utf8_regexp_waits_for_incomplete_trailing_character_before_matching
    session, writer = pipe_session
    session.buffer = "ready\xE4".b

    assert_nil session.expect(/ready\z/u, timeout: 0)
    assert_nil session.expect(/ready/u, timeout: 0)
    assert_equal "ready\xE4".b, session.buffer

    writer.write("\xB8\xAD".b)
    assert_equal 1, session.expect(/ready中\z/u, timeout: 1)
    assert_equal "ready中".b, session.match
  end

  def test_binary_nul_and_invalid_utf8
    session, writer = pipe_session
    writer.write("\xff\x00abc\xfe".b)
    assert_equal 1, session.expect(/\x00(abc)/n, timeout: 1)
    assert_equal "\xff".b, session.before
    assert_equal ["abc"], session.captures
  end

  def test_utf8_regexp_rejects_impossible_partial_characters
    session, = pipe_session
    ["\xE0\x80", "\xED\xA0", "\xF0\x80", "\xF4\x90"].each do |bytes|
      session.buffer = bytes.b
      assert_raises(EncodingError) { session.expect(/ready/u, timeout: 0) }
      assert_equal bytes.b, session.buffer
    end
  end

  def test_utf8_regexp_accepts_valid_partial_characters
    session, = pipe_session
    ["¢", "中", "😀", "\u{10FFFF}"].each do |character|
      1.upto(character.bytesize - 1) do |length|
        session.buffer = character.b.byteslice(0, length)
        assert_nil session.expect(/./u, timeout: 0)
        assert_equal character.b.byteslice(0, length), session.buffer
      end
    end
  end

  def test_native_regexp_anchors_and_flags
    session, = pipe_session
    session.buffer = "a\nb\nc"
    session.preserve_buffer = true
    assert_nil session.expect("^b$", timeout: 0)
    assert_nil session.expect(/\Ab\z/, timeout: 0)
    assert_equal 1, session.expect(/^b$/, timeout: 0)
    assert_equal 1, session.expect(/a.b/m, timeout: 0)
    assert_nil session.expect(/a.b/, timeout: 0)
  end

  def test_eof_callback_consumes_remaining_buffer
    session, writer = pipe_session
    writer.write("last bytes")
    writer.close
    seen = nil
    result = session.expect_result(timeout: 1) { eof { |object| seen = object.before } }
    assert_nil result.number
    assert result.eof?
    assert_equal "last bytes", seen
    assert_empty session.buffer
  end

  def test_read_without_patterns_and_match_before_eof
    session, writer = pipe_session
    writer.write("END")
    writer.close
    assert_equal 1, session.expect("END", timeout: nil)
    assert session.expect_result(timeout: nil).eof?
  end

  def test_argument_validation_does_not_read_io
    session, = pipe_session
    assert_raises(ArgumentError) { session.expect("x", timeout: -1) }
    assert_raises(ArgumentError) { session.expect("x", timeout: Float::INFINITY) }
    assert_raises(ArgumentError) { session.expect(["a", 42], timeout: 0) }
    assert_raises(ArgumentError) { session.expect("-i", [], timeout: 0) }
    assert_raises(ArgumentError) { session.expect(Object.new, timeout: 0) }
    assert_raises(ArgumentError) { Expect.expect("x", timeout: 0) }
    assert_raises(ArgumentError) { session.buffer_limit = -1 }
  end
end
