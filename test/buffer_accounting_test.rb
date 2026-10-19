# frozen_string_literal: true

require_relative "test_helper"

class BufferAccountingTest < ExpectTest
  # 大输出预算只需要当前主缓冲的字节数，不能为查询而读取、消费或复制正文。
  def test_buffer_bytesize_tracks_receiving_trimming_consumption_and_eof
    session, writer = pipe_session(buffer_limit: 8)
    assert_respond_to session, :buffer_bytesize
    assert_equal 0, session.buffer_bytesize
    session.buffer = "中ab"
    assert_equal 5, session.buffer_bytesize
    assert_equal 1, session.expect("中", timeout: 0).number
    assert_equal 2, session.buffer_bytesize

    writer.write("cd€")
    assert_equal 2, session.buffer_bytesize
    session.expect("missing", timeout: 0)
    assert_equal 7, session.buffer_bytesize
    session.buffer_limit = 4
    assert_equal 4, session.buffer_bytesize
    assert_equal 1, session.expect("d", timeout: 0, consume: false).number
    assert_equal 4, session.buffer_bytesize
    session.buffer.clear
    assert_equal 4, session.buffer_bytesize

    writer.close
    assert_equal "d€".b, session.expect(:eof, timeout: 1).before
    assert_equal 0, session.buffer_bytesize
  end

  def test_buffer_bytesize_tracks_explicit_clearing_without_resetting_discard_count
    session, = pipe_session(buffer_limit: 4)
    assert_respond_to session, :buffer_bytesize
    session.buffer = "abcdef"
    assert_equal 4, session.buffer_bytesize
    assert_equal "cdef", session.clear_buffer
    assert_equal 0, session.buffer_bytesize
    assert_equal 2, session.buffer_discarded_bytes
  end

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
    session.transcript = write_target { |data| logged += data.bytesize }
    32.times do
      writer.write("x" * 4096)
      assert_nil session.expect("missing", timeout: 0).number
      assert_equal 64, session.buffer.bytesize
    end
    assert_equal 131_072, logged
    assert_equal logged - 64, session.buffer_discarded_bytes
  end

  def test_preserved_match_does_not_count_as_discard
    session, = pipe_session(buffer_limit: 4)
    session.buffer = "abcdef"
    2.times { assert_equal 1, session.expect("ef", timeout: 0, consume: false).number }
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
  end

  def test_relay_tail_is_only_counted_when_matching_applies_the_limit
    session, writer = pipe_session(buffer_limit: 2)
    output = StringIO.new
    session.outputs = [output]
    session.on_sequence("STOP")
    writer.write("prefixSTOPtail")
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "prefix", output.string
    assert_equal "tail", session.buffer
    assert_equal 4, session.buffer_bytesize
    assert_equal 0, session.buffer_discarded_bytes
    assert_equal 1, session.expect("il", timeout: 0).number
    assert_equal 0, session.buffer_bytesize
    assert_equal 2, session.buffer_discarded_bytes
    session.expect(timeout: 0)
    assert_equal 2, session.buffer_discarded_bytes
  end

  def test_logging_failure_preserves_the_retained_input_and_discard_count
    session, writer = pipe_session(buffer_limit: 4)
    failure = IOError.new("log failed")
    session.transcript = write_target { raise failure }
    writer.write("abcdef")
    assert_same failure, session.expect("ef", timeout: 1).error
    assert_equal "cdef", session.buffer
    assert_equal 2, session.buffer_discarded_bytes
    session.transcript = nil
    assert_equal 1, session.expect("ef", timeout: 0).number
    assert_equal 2, session.buffer_discarded_bytes
  end
end
