# frozen_string_literal: true

require_relative "test_helper"

class TimeoutTest < ExpectTest
  def test_default_timeout_and_explicit_infinite_timeout
    session, writer = pipe_session
    session.timeout = 0.01
    assert_nil session.expect("ready").number
    background do
      sleep 0.04
      writer.write("ready")
    end
    assert_equal(1, bounded { session.expect("ready", timeout: nil).number })
  end

  def test_zero_timeout_polls_existing_data_without_waiting
    session, writer = pipe_session
    writer.write("ready")
    assert_equal 1, session.expect("ready", timeout: 0).number
    start = Expect.monotonic
    assert_nil session.expect("missing", timeout: 0).number
    assert_operator Expect.monotonic - start, :<, 0.1
  end

  def test_continue_resets_timeout
    session, writer = pipe_session
    number = with_timed_input(writer, [[7, "A"], [16, "B"]]) do
      session.expect(timeout: 13) do
        on("A") { Expect.continue }
        on("B")
      end.number
    end
    assert_equal 2, number
  end

  def test_continue_timeout_preserves_deadline
    session, writer = pipe_session
    number = with_timed_input(writer, [[7, "A"], [19, "B"]]) do
      result = session.expect(timeout: 14) do
        on("A") { Expect.continue(reset_timeout: false) }
        on("B")
      end.number
      assert_equal 14, Expect.monotonic
      result
    end
    assert_nil number
    assert_equal :timeout, session.error
  end

  def test_eof_continuation_without_reset_observes_the_deadline_before_matching_again
    first, = pipe_session
    second, = pipe_session
    first.close
    now = 0.0
    result = Expect.stub(:monotonic, -> { now }) do
      Expect.expect(timeout: 1) do
        eof(from: first) do
          now = 2.0
          second.buffer = "ready"
          Expect.continue(reset_timeout: false)
        end
        on("ready", from: second)
      end
    end

    assert result.timeout?
    assert_same second, result.session
    assert_equal "ready", second.buffer
    assert first.last_result.eof?
  end

  def test_eof_continuation_can_reset_an_expired_deadline
    first, = pipe_session
    second, = pipe_session
    first.close
    now = 0.0
    result = Expect.stub(:monotonic, -> { now }) do
      Expect.expect(timeout: 1) do
        eof(from: first) do
          now = 2.0
          second.buffer = "ready"
          Expect.continue
        end
        on("ready", from: second)
      end
    end

    assert_equal "ready", result.match
    assert_same second, result.session
  end

  def test_last_eof_returns_even_when_continuation_deadline_has_expired
    session, = pipe_session
    session.close
    now = 0.0
    result = Expect.stub(:monotonic, -> { now }) do
      session.expect(timeout: 1) do
        eof do
          now = 2.0
          Expect.continue(reset_timeout: false)
        end
      end
    end

    assert result.eof?
    assert_same session, result.session
  end

  def test_expired_eof_continuation_delivers_all_known_eof_events
    sessions = Array.new(3) { pipe_session.first }
    sessions.each(&:close)
    seen = []
    result = Expect.expect(from: sessions, timeout: 0) do
      eof do |session|
        seen << session
        Expect.continue(reset_timeout: false)
      end
    end

    assert result.eof?
    assert_equal sessions, seen
    assert(sessions.all? { |session| session.last_result.eof? })
  end

  def test_expired_eof_continuation_handles_known_eof_before_timing_out_live_sources
    first, = pipe_session
    second, = pipe_session
    live, = pipe_session
    [first, second].each(&:close)
    seen = []
    timed_out = nil
    result = Expect.expect(timeout: 0) do
      eof(from: [first, second]) do |session|
        seen << session
        live.buffer = "ready"
        Expect.continue(reset_timeout: false)
      end
      on("ready", from: live)
      timeout { |sessions| timed_out = sessions }
    end

    assert result.timeout?
    assert_equal [first, second], seen
    assert_equal [live], timed_out
    assert_equal "ready", live.buffer
  end

  def test_reset_after_expired_eof_continuation_resumes_text_matching
    %i[eof timeout].each do |reset_event|
      first, = pipe_session
      second, = pipe_session
      live, = pipe_session
      [first, second].each(&:close)
      result = Expect.expect(timeout: 0) do
        eof(from: first) do
          live.buffer = "ready"
          Expect.continue(reset_timeout: false)
        end
        eof(from: second) { Expect.continue(reset_timeout: reset_event == :eof) }
        on("ready", from: live)
        timeout { Expect.continue }
      end

      assert_equal "ready", result.match
      assert_same live, result.session
    end
  end

  def test_restart_timeout_on_receive
    session, writer = pipe_session
    session.reset_timeout_on_read = true
    number = with_timed_input(writer, [[6, "."], [12, "."], [18, "."], [24, ".done"]]) do
      session.expect("done", timeout: 10).number
    end
    assert_equal 1, number
  end

  def test_receive_keeps_deadline_without_reset
    session, writer = pipe_session
    result = with_timed_input(writer, [[6, "."], [12, "done"]]) do
      session.expect("done", timeout: 10)
    end
    assert result.timeout?
    assert_equal ".", session.buffer
  end

  def test_timeout_callback_receives_group_and_can_retry
    session, = pipe_session
    count = 0
    groups = []
    argument = :value
    number = session.expect(timeout: 0.01) do
      timeout do |objects|
        groups << [objects, argument]
        count += 1
        count < 3 ? Expect.continue : nil
      end
    end.number
    assert_nil number
    assert_equal 3, count
    assert_equal [[[session], :value]] * 3, groups
  end

  def test_callback_exception_propagates
    session, = pipe_session
    session.buffer = "ready"
    assert_raises(RuntimeError) do
      session.expect(timeout: 0) { on("ready") { raise "handler failed" } }.number
    end
    assert_equal "ready", session.match
  end

  def test_continuation_through_buffered_states
    session, = pipe_session
    session.buffer = "A B C D End"
    states = []
    number = session.expect(timeout: 1) do
      on(/[ABCD]/) do |connection|
        states << connection.match
        connection.continue
      end
      on("End")
    end.number
    assert_equal 2, number
    assert_equal %w[A B C D], states
  end

  def test_absolute_timeout_even_with_continuous_unmatched_output
    session = child('loop { print "x" * 16384 }', raw_pty: true, buffer_limit: 1024)
    start = Expect.monotonic
    result = bounded(2) { session.expect("missing", timeout: 0.05) }
    assert result.timeout?
    assert_operator Expect.monotonic - start, :<, 0.4
  end

  def test_repeated_select_interruptions_do_not_extend_the_deadline
    session, = pipe_session
    interrupted = lambda do |*|
      sleep 0.01
      raise Errno::EINTR
    end
    result = bounded(1) do
      IO.stub(:select, interrupted) { session.expect("missing", timeout: 0.02) }
    end
    assert result.timeout?
  end

  def test_interrupted_read_retries_without_losing_input
    session, writer = pipe_session
    writer.write("ready")
    original = session.to_io.method(:read_nonblock)
    interrupted = true
    read = lambda do |*args, **options|
      if interrupted
        interrupted = false
        raise Errno::EINTR
      end
      original.call(*args, **options)
    end
    session.to_io.stub(:read_nonblock, read) do
      assert_equal 1, session.expect("ready", timeout: 1).number
    end
    assert_equal "ready", session.match
  end

  private

  # 按虚拟时间向真实管道写入数据；select 仍按调用方给定的期限决定就绪或超时。
  # 这样可精确检查期限是否重置，不依赖 CI 线程能否在几十毫秒内获得调度。
  def with_timed_input(writer, events, &)
    now = 0.0
    pending = events.dup
    select = lambda do |readers, _writers, _errors, timeout|
      deadline = now + timeout
      if pending.any? && pending.first[0] <= deadline
        now, data = pending.shift
        writer.write(data)
        [readers, [], []]
      else
        now = deadline
        nil
      end
    end
    Expect.stub(:monotonic, -> { now }) do
      IO.stub(:select, select, &)
    end
  end
end
