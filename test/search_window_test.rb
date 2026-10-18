# frozen_string_literal: true

require_relative "test_helper"

class SearchWindowTest < ExpectTest
  def test_literal_window_misses_do_not_allocate_a_tail_per_scan
    pattern = Expect.const_get(:Pattern, false).new(value: "absent")
    buffer = ("x" * 1_048_576).b
    10.times { pattern.locate(buffer, search_window: 65_536) }
    before = GC.stat(:total_allocated_objects)
    1000.times { pattern.locate(buffer, search_window: 65_536) }
    allocated = GC.stat(:total_allocated_objects) - before
    assert_operator allocated, :<, 250, "repeated misses should search the original byte buffer"
  end

  def test_literal_window_matches_a_binary_tail_reference
    random = Random.new(20_261_018)
    session, = pipe_session
    200.times do
      buffer = random.bytes(random.rand(1..80))
      window = random.rand(1..90)
      pattern = if random.rand(2).zero?
                  random.bytes(random.rand(0..8))
                else
                  buffer.byteslice(random.rand(buffer.bytesize), random.rand(0..8))
                end
      start = [buffer.bytesize - window, 0].max
      offset = buffer.byteslice(start..).index(pattern)
      session.buffer = buffer
      result = session.expect(pattern, search_window: window, timeout: 0, consume: false)
      if offset
        assert_equal [buffer.byteslice(0, start + offset), pattern,
                      buffer.byteslice((start + offset + pattern.bytesize)..)],
                     [result.before, result.match, result.after]
      else
        assert result.timeout?
      end
      assert_equal buffer, session.buffer
    end
  end

  def test_window_limits_literals_and_regular_expressions_without_dropping_buffer
    ["old", /old/].each do |pattern|
      session, = pipe_session
      session.buffer = "old---new"
      assert session.expect(pattern, search_window: 3, timeout: 0).timeout?
      assert_equal "old---new", session.buffer
    end
  end

  def test_match_offsets_and_consumption_refer_to_the_complete_buffer
    session, = pipe_session
    session.buffer = "prefix-TARGET-tail"
    result = session.expect(/TARGET/, search_window: 11, timeout: 0, consume: false)
    assert_equal ["prefix-", "TARGET", "-tail"], [result.before, result.match, result.after]
    assert_equal "prefix-TARGET-tail", session.buffer
    result = session.expect("TARGET", search_window: 11, timeout: 0)
    assert_equal "prefix-", result.before
    assert_equal "-tail", session.buffer
  end

  def test_utf8_window_skips_only_a_split_leading_character
    session, = pipe_session
    session.buffer = "prefixé好ok"
    result = session.expect(/好ok/, search_window: 6, timeout: 0)
    assert_equal "好ok".b, result.match
    assert_equal "prefixé".b, result.before
  end

  def test_window_has_independent_anchor_semantics
    session, = pipe_session
    session.buffer = "prefix-tail"
    assert_equal "tail", session.expect(/\Atail/, search_window: 4, timeout: 0).match
  end

  def test_invalid_window_rejects_before_registration
    session, = pipe_session
    [0, -1, 1.5, "5", true].each do |value|
      assert_raises(ArgumentError) { session.expect(search_window: value) { flunk "unexpected registration" } }
    end
  end

  def test_top_level_and_responder_forward_the_window
    first, = pipe_session
    second, = pipe_session
    first.buffer = "old---tail"
    second.buffer = "old---win"
    assert_equal second, Expect.expect("win", from: [first, second], search_window: 3, timeout: 0).session
    assert_equal "tail", Expect::Responder.new.expect(first, /\Atail/, search_window: 4, timeout: 0).match
  end

  def test_binary_window_preserves_exact_bytes
    session, = pipe_session
    session.buffer = "old\xff\x00tail".b
    result = session.expect(/\xff\x00/n, search_window: 6, timeout: 0)
    assert_equal "\xff\x00".b, result.match
    assert_equal "old", result.before
    assert_equal "tail", result.after
  end

  def test_window_does_not_hide_invalid_utf8_inside_the_window
    session, = pipe_session
    session.buffer = "old\xff好".b
    assert_raises(EncodingError) { session.expect(/好/, search_window: 4, timeout: 0) }
  end

  def test_zero_width_match_maps_back_to_full_buffer
    session, = pipe_session
    session.buffer = "prefix-tail"
    result = session.expect(/\A/, search_window: 4, timeout: 0)
    assert_equal ["prefix-", "", "tail"], [result.before, result.match, result.after]
  end

  def test_streamed_match_can_span_read_boundaries_inside_window
    session, writer = pipe_session
    session.buffer = "prefix-TA"
    writer.write("RGET-tail")
    result = session.expect(/TARGET/, search_window: 11, timeout: 1)
    assert_equal ["prefix-", "TARGET", "-tail"], [result.before, result.match, result.after]
  end

  def test_nil_window_preserves_full_buffer_matching
    session, = pipe_session
    session.buffer = "old---tail"
    assert_equal "old", session.expect(/\Aold/, search_window: nil, timeout: 0).match
  end

  def test_split_leading_character_can_also_be_an_incomplete_trailing_character
    session, writer = pipe_session
    session.buffer = "prefix\xf0\x9f\x98".b
    assert session.expect(/😀/, search_window: 2, timeout: 0).timeout?
    writer.write("\x80ok".b)
    assert_equal "ok", session.expect(/ok/, search_window: 2, timeout: 1).match
  end

  def test_eof_rejects_split_incomplete_character
    session, writer = pipe_session
    session.buffer = "prefix\xf0\x9f\x98".b
    writer.close
    assert_raises(EncodingError) { session.expect(/😀/, search_window: 2, timeout: 1) }
  end
end
