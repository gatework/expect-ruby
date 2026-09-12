# frozen_string_literal: true

require_relative "test_helper"

class TimeoutTest < ExpectTest
  def test_default_timeout_and_explicit_infinite_timeout
    session, writer = pipe_session
    session.timeout = 0.01
    assert_nil session.expect("ready")
    background do
      sleep 0.04
      writer.write("ready")
    end
    assert_equal(1, bounded { session.expect("ready", timeout: nil) })
  end

  def test_zero_timeout_polls_existing_data_without_waiting
    session, writer = pipe_session
    writer.write("ready")
    assert_equal 1, session.expect("ready", timeout: 0)
    start = Expect.monotonic
    assert_nil session.expect("missing", timeout: 0)
    assert_operator Expect.monotonic - start, :<, 0.1
  end

  def test_continue_resets_timeout
    session, writer = pipe_session
    number = with_timed_input(writer, [[7, "A"], [16, "B"]]) do
      session.expect(timeout: 13) do
        on("A") { Expect.continue }
        on("B")
      end
    end
    assert_equal 2, number
  end

  def test_continue_timeout_preserves_deadline
    session, writer = pipe_session
    number = with_timed_input(writer, [[7, "A"], [19, "B"]]) do
      result = session.expect(timeout: 14) do
        on("A") { Expect.continue(reset_timeout: false) }
        on("B")
      end
      assert_equal 14, Expect.monotonic
      result
    end
    assert_nil number
    assert_equal :timeout, session.error
  end

  def test_restart_timeout_on_receive
    session, writer = pipe_session
    session.reset_timeout_on_read = true
    number = with_timed_input(writer, [[6, "."], [12, "."], [18, "."], [24, ".done"]]) do
      session.expect("done", timeout: 10)
    end
    assert_equal 1, number
  end

  def test_receive_keeps_deadline_without_reset
    session, writer = pipe_session
    result = with_timed_input(writer, [[6, "."], [12, "done"]]) do
      session.expect_result("done", timeout: 10)
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
    end
    assert_nil number
    assert_equal 3, count
    assert_equal [[[session], :value]] * 3, groups
  end

  def test_callback_exception_propagates
    session, = pipe_session
    session.buffer = "ready"
    assert_raises(RuntimeError) do
      session.expect(timeout: 0) { on("ready") { raise "handler failed" } }
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
    end
    assert_equal 2, number
    assert_equal %w[A B C D], states
  end

  def test_absolute_timeout_even_with_continuous_unmatched_output
    session = child('loop { print "x" * 16384 }', raw_pty: true, buffer_limit: 1024)
    start = Expect.monotonic
    result = bounded(2) { session.expect_result("missing", timeout: 0.05) }
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
      IO.stub(:select, interrupted) { session.expect_result("missing", timeout: 0.02) }
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
      assert_equal 1, session.expect("ready", timeout: 1)
    end
    assert_equal "ready", session.match
  end

  private

  # 按虚拟时间向真实管道写入数据；select 仍按调用方给定的期限决定就绪或超时。
  # 这样可精确检查期限是否重置，不依赖 CI 线程能否在几十毫秒内获得调度。
  def with_timed_input(writer, events, &block)
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
      IO.stub(:select, select, &block)
    end
  end
end
