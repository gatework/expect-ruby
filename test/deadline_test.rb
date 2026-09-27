# frozen_string_literal: true

require_relative "test_helper"

class DeadlineTest < ExpectTest
  def test_absolute_deadline_caps_timeout_resets_from_incoming_data
    session, writer = pipe_session(reset_timeout_on_read: true)
    with_clock([[4, writer, "."], [8, writer, "."], [12, writer, "done"]]) do |clock|
      result = session.expect_result("done", timeout: 5, deadline: 10)
      assert result.timeout?
      assert_equal 10, clock[0]
      assert_equal "..", session.buffer
    end
  end

  def test_class_api_and_nil_timeout_use_the_absolute_deadline
    session, writer = pipe_session
    with_clock([[4, writer, "ready"]]) do |clock|
      assert_equal 1, Expect.expect("ready", from: session, timeout: nil, deadline: 5)
      result = Expect.expect_result("missing", from: session, timeout: nil, deadline: 5)
      assert result.timeout?
      assert_equal 5, clock[0]
    end
  end

  def test_shorter_relative_timeout_still_wins
    session, = pipe_session
    with_clock do |clock|
      assert session.expect_result("missing", timeout: 2, deadline: 10).timeout?
      assert_equal 2, clock[0]
    end
  end

  def test_continuing_match_cannot_extend_the_hard_deadline
    session, = pipe_session
    session.buffer = "first second"
    with_clock do |clock|
      result = session.expect_result(timeout: 10, deadline: 5) do
        on("first") do
          clock[0] = 6
          Expect.continue
        end
        on("second") { flunk "must not consume text after the deadline" }
      end
      assert result.timeout?
      assert_equal " second", session.buffer
    end
  end

  def test_timeout_callback_cannot_restart_an_expired_hard_deadline
    session, = pipe_session
    calls = 0
    with_clock do |clock|
      result = session.expect_result(timeout: 3, deadline: 5) do
        timeout do
          calls += 1
          Expect.continue
        end
      end
      assert result.timeout?
      assert_equal 2, calls
      assert_equal 5, clock[0]
    end
  end

  def test_expired_deadline_does_not_scan_or_read_and_preserves_input
    session, writer = pipe_session
    session.buffer = "buffered"
    writer.write("unread")
    with_clock do |clock|
      clock[0] = 5
      assert session.expect_result("buffered", timeout: 0, deadline: 5).timeout?
      assert_equal "buffered", session.buffer
      assert_equal "unread", session.to_io.read_nonblock(6)
    end
  end

  def test_zero_relative_timeout_still_polls_with_a_future_hard_deadline
    session, writer = pipe_session
    writer.write("ready")
    assert_equal 1, session.expect("ready", timeout: 0, deadline: Expect.monotonic + 1)
  end

  def test_repeated_interruptions_cannot_extend_a_deadline
    session, = pipe_session
    clock = [0]
    Expect.stub(:monotonic, -> { clock[0] }) do
      IO.stub(:select, lambda { |*|
        clock[0] += 1
        raise Errno::EINTR
      }) do
        assert session.expect_result("missing", deadline: 3).timeout?
      end
      assert_equal 3, clock[0]
    end
  end

  def test_known_eof_events_are_delivered_before_timeout_of_live_sources
    ended, = pipe_session
    live, = pipe_session
    ended.close
    live.buffer = "ready"
    seen = []
    with_clock do
      result = Expect.expect_result(from: [ended, live], deadline: 0) do
        on("ready") { flunk "deadline already expired" }
        eof(from: ended) do
          seen << :eof
          Expect.continue
        end
        timeout { |sessions| seen << sessions }
      end
      assert result.timeout?
      assert_same live, result.session
      assert_equal [:eof, [live]], seen
      assert_equal "ready", live.buffer
    end
  end

  def test_all_known_eof_returns_eof_even_at_the_hard_deadline
    first, = pipe_session
    second, = pipe_session
    [first, second].each(&:close)
    seen = []
    with_clock do
      result = Expect.expect_result(from: [first, second], deadline: 0) do
        eof do |session|
          seen << session
          Expect.continue
        end
        timeout { flunk "all sources ended" }
      end
      assert result.eof?
      assert_equal [first, second], seen
    end
  end

  def test_deadline_reached_during_regexp_does_not_consume_the_match
    session, = pipe_session
    session.buffer = "ready"
    pattern = Regexp.new("ready")
    match = pattern.method(:match)
    with_clock do |clock|
      pattern.stub(:match, lambda { |text|
        clock[0] = 5
        match.call(text)
      }) do
        assert session.expect_result(pattern, deadline: 5).timeout?
      end
      assert_equal "ready", session.buffer
    end
  end

  def test_preserved_timeout_at_hard_deadline_still_dispatches_all_known_eof
    first, = pipe_session
    second, = pipe_session
    [first, second].each(&:close)
    first.buffer = "ready"
    seen = []
    with_clock do |clock|
      result = Expect.expect_result(from: [first, second], deadline: 5) do
        on("ready") do
          clock[0] = 5
          Expect.continue(reset_timeout: false)
        end
        eof do |session|
          seen << session
          Expect.continue(reset_timeout: false)
        end
        timeout { seen << :timeout }
      end
      assert result.eof?
      assert_equal [first, second], seen
    end
  end

  def test_preserved_timeout_at_hard_deadline_only_times_out_live_sources
    ended, = pipe_session
    live, = pipe_session
    ended.close
    ended.buffer = "ready"
    seen = []
    with_clock do |clock|
      result = Expect.expect_result(from: [ended, live], deadline: 5) do
        on("ready") do
          clock[0] = 5
          Expect.continue(reset_timeout: false)
        end
        eof(from: ended) do
          seen << :eof
          Expect.continue(reset_timeout: false)
        end
        timeout { |sessions| seen << sessions }
      end
      assert result.timeout?
      assert_same live, result.session
      assert_equal [:eof, [live]], seen
    end
  end

  def test_invalid_deadlines_are_rejected_before_the_definition_or_io
    session, writer = pipe_session
    writer.write("ready")
    [Float::INFINITY, -Float::INFINITY, Float::NAN, "invalid"].each do |deadline|
      assert_raises(ArgumentError) do
        session.expect_result(deadline: deadline) { flunk "invalid deadline must reject before registration" }
      end
    end
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  private

  # 虚拟时间只控制等待，数据仍经真实管道；精确断言上限，不依赖线程调度和 sleep。
  def with_clock(events = [])
    clock = [0.0]
    pending = events.dup
    poll = IO.method(:select)
    select = lambda do |readers, writers, errors, timeout|
      due = timeout && (clock[0] + timeout)
      if pending.any? && (!due || pending.first[0] <= due)
        at, writer, data = pending.shift
        clock[0] = at
        writer.write(data)
        poll.call(readers, writers, errors, 0)
      else
        raise "unbounded wait without input" unless due

        clock[0] = due
        nil
      end
    end
    Expect.stub(:monotonic, -> { clock[0] }) do
      IO.stub(:select, select) { yield clock }
    end
  end
end
