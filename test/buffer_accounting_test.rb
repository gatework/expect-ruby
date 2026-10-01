# frozen_string_literal: true

require_relative "test_helper"

class BufferAccountingTest < ExpectTest
  def test_limit_discards_are_cumulative_and_distinct_from_consumption
    session, = pipe_session(buffer_limit: 4)
    assert_equal 0, session.buffer_discarded_bytes
    session.buffer = "abcdef"
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
    session.buffer_limit = 2
    assert_equal "ef", session.buffer
    assert_equal 4, session.buffer_discarded_bytes
    assert_equal 1, session.expect("e", timeout: 0).number
    assert_equal "f", session.clear_buffer
    session.close
    assert_equal 4, session.buffer_discarded_bytes
    refute_respond_to session, :buffer_discarded_bytes=
  end

  def test_invalid_limit_and_buffer_leave_accounting_unchanged
    session, = pipe_session(buffer_limit: 4)
    session.buffer = "abcdef"
    assert_raises(ArgumentError) { session.buffer_limit = 0 }
    assert_raises(ArgumentError) { session.buffer = nil }
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
    session.buffer_limit = nil
    session.buffer = "unlimited"
    assert_equal 2, session.buffer_discarded_bytes
  end

  def test_continuous_output_keeps_a_bounded_window_and_complete_log
    session, writer = pipe_session(buffer_limit: 64)
    logged = 0
    session.log_to { |data| logged += data.bytesize }
    32.times do
      writer.write("x" * 4096)
      assert_nil session.expect("missing", timeout: 0).number
      assert_equal 64, session.buffer.bytesize
    end
    assert_equal 131_072, logged
    assert_equal logged - 64, session.buffer_discarded_bytes
  end

  def test_preserved_match_does_not_count_as_discard
    session, = pipe_session(buffer_limit: 4, preserve_buffer: true)
    session.buffer = "abcdef"
    2.times { assert_equal 1, session.expect("ef", timeout: 0).number }
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
  end

  def test_relay_tail_is_only_counted_when_matching_applies_the_limit
    session, writer = pipe_session(buffer_limit: 2)
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence("STOP")
    writer.write("prefixSTOPtail")
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "prefix", output.string
    assert_equal "tail", session.buffer
    assert_equal 0, session.buffer_discarded_bytes
    assert_equal 1, session.expect("il", timeout: 0).number
    assert_equal 2, session.buffer_discarded_bytes
    session.expect(timeout: 0)
    assert_equal 2, session.buffer_discarded_bytes
  end

  def test_logging_failure_preserves_the_retained_input_and_discard_count
    session, writer = pipe_session(buffer_limit: 4)
    failure = IOError.new("log failed")
    session.log_to { raise failure }
    writer.write("abcdef")
    assert_same failure, session.expect("ef", timeout: 1).error
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
    session.log_output = nil
    assert_equal 1, session.expect("ef", timeout: 0).number
    assert_equal 2, session.buffer_discarded_bytes
  end
end
