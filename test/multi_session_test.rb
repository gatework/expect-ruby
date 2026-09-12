# frozen_string_literal: true

require_relative "test_helper"

class MultiSessionTest < ExpectTest
  def test_multi_session_pattern_groups_and_global_numbering
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.write("irrelevant")
    second_writer.write("second:42")
    result = Expect.expect_result(timeout: 1) do
      on("first", from: first)
      on(/second:(\d+)/, from: second)
    end
    assert_equal 2, result.number
    assert_same second, result.session
    assert_equal ["42"], result.captures
    assert_equal "irrelevant", first.buffer
  end

  def test_shared_patterns_across_sessions
    first, = pipe_session
    second, writer = pipe_session
    writer.write("ready")
    assert_equal 1, Expect.expect("ready", from: [first, second], timeout: 1)
    assert_equal "ready", second.match
  end

  def test_eof_continue_removes_closed_session_and_waits_for_remaining
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.close
    ended = []
    result = Expect.expect_result(timeout: 1) do
      eof(from: first) do |connection|
        ended << connection
        second_writer.write("done")
        Expect.continue(reset_timeout: false)
      end
      on("done", from: second)
    end
    assert_equal [first], ended
    assert_equal 2, result.number
    assert_same second, result.session
  end

  def test_all_eof_continuation_returns_without_waiting_forever
    first, writer = pipe_session
    writer.close
    result = bounded { first.expect_result(timeout: nil) { eof { Expect.continue } } }
    assert result.eof?
  end

  def test_same_session_in_multiple_groups_is_read_once
    session, writer = pipe_session
    writer.write("right")
    other, = pipe_session
    result = Expect.expect_result(timeout: 1) do
      on("wrong", from: session)
      on("missing", from: other)
      on("right", from: session)
    end
    assert_equal 3, result.number
    assert_equal "right", result.match
  end
end
