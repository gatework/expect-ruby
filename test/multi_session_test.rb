# frozen_string_literal: true

require_relative "test_helper"

class MultiSessionTest < ExpectTest
  def test_multi_session_pattern_groups_and_global_numbering
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.write("irrelevant")
    second_writer.write("second:42")
    result = Expect.expect(timeout: 1) do
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
    assert_equal 1, Expect.expect("ready", from: [first, second], timeout: 1).number
    assert_equal "ready", second.match
  end

  def test_eof_continue_removes_closed_session_and_waits_for_remaining
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.close
    ended = []
    result = Expect.expect(timeout: 1) do
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
    result = bounded { first.expect(timeout: nil) { eof { Expect.continue } } }
    assert result.eof?
  end

  def test_known_eof_continuation_dispatches_duplicate_sources_once_in_order
    first, = pipe_session
    second, = pipe_session
    third, = pipe_session
    [first, second, third].each_with_index do |session, index|
      session.buffer = "tail-#{index}"
      session.close
    end
    seen = []

    result = Expect.expect(from: [second, first, second, third, first], timeout: 0) do
      eof do |session|
        seen << [session, session.before, session.buffer]
        Expect.continue(reset_timeout: false)
      end
    end

    assert result.eof?
    assert_same third, result.session
    assert_equal "tail-2", result.before
    assert_equal [[second, "tail-1", ""], [first, "tail-0", ""], [third, "tail-2", ""]], seen
  end

  def test_select_failure_only_updates_sources_still_being_monitored
    ended, = pipe_session
    first_live, = pipe_session
    second_live, = pipe_session
    ended.buffer = "final tail"
    ended.close
    failure = IOError.new("select failed")
    ended_result = nil

    result = IO.stub(:select, ->(*) { raise failure }) do
      Expect.expect(from: [ended, first_live, second_live], timeout: 1) do
        eof(from: ended) do |session|
          ended_result = session.last_result
          Expect.continue(reset_timeout: false)
        end
      end
    end

    assert_same first_live, result.session
    assert_same failure, result.error
    assert_same failure, second_live.error
    assert_same ended_result, ended.last_result
    assert ended.last_result.eof?
    assert_equal "final tail", ended.before
  end

  def test_same_session_in_multiple_groups_is_read_once
    session, writer = pipe_session
    writer.write("right")
    other, = pipe_session
    result = Expect.expect(timeout: 1) do
      on("wrong", from: session)
      on("missing", from: other)
      on("right", from: session)
    end
    assert_equal 3, result.number
    assert_equal "right", result.match
  end

  def test_equal_session_values_do_not_remove_independent_readers
    first, = pipe_session
    second, writer = pipe_session
    equalize_sessions(first, second)
    writer.write("ready")

    result = Expect.expect("ready", from: [first, second], timeout: 0)

    assert result.matched?
    assert_same second, result.session
    assert_empty first.buffer
  end

  def test_equal_session_values_do_not_merge_distinct_pattern_groups
    first, = pipe_session
    second, = pipe_session
    equalize_sessions(first, second)
    first.buffer = "second"
    second.buffer = "second"

    result = Expect.expect(timeout: 0) do
      on("first", from: first)
      on("second", from: second)
    end

    assert_same second, result.session
    assert_equal "second", first.buffer
    assert_empty second.buffer
  end

  def test_timeout_sources_keep_identity_and_first_declaration_order
    first, = pipe_session
    second, = pipe_session
    equalize_sessions(first, second)
    sources = nil

    result = Expect.expect(from: [second, first, second], timeout: 0) do
      timeout { |sessions| sources = sessions }
    end

    assert result.timeout?
    assert_same second, result.session
    assert_equal 2, sources.length
    assert_same second, sources[0]
    assert_same first, sources[1]
  end

  def test_equal_session_values_do_not_share_eof_callbacks
    first, = pipe_session
    second, = pipe_session
    live, = pipe_session
    equalize_sessions(first, second)
    [first, second].each(&:close)
    seen = []

    result = Expect.expect(timeout: 0) do
      eof(from: first) do |session|
        seen << [:first, session]
        Expect.continue
      end
      on("missing", from: live)
      eof(from: second) do |session|
        seen << [:second, session]
        Expect.continue
      end
    end

    assert result.timeout?
    assert_same live, result.session
    assert_equal %i[first second], seen.map(&:first)
    assert_same first, seen[0][1]
    assert_same second, seen[1][1]
  end
end
