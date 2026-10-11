# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class SoftCloseFailureTest < ExpectTest
  def test_read_failure_still_closes_owned_handles_and_preserves_the_error
    [IOError.new("read failed"), RuntimeError.new("delivery failed"),
     Interrupt.new("read interrupted"), SystemExit.new(17)].each do |primary|
      session, = pipe_session(own: true)
      session.to_io.stub(:wait_readable, ->(*) { raise primary }) do
        assert_same primary, assert_raises(primary.class) { session.soft_close(timeout: 1, term_timeout: 0) }
      end
      assert session.closed?
      assert session.to_io.closed?
    end
  end

  def test_failed_drain_skips_natural_wait_even_with_unbounded_timeout
    session, = pipe_session(own: true)
    primary = IOError.new("read failed")
    calls = []
    session.stub(:close_child, ->(**options) { calls << options }) do
      session.to_io.stub(:wait_readable, ->(*) { raise primary }) do
        assert_same primary, assert_raises(IOError) { session.soft_close(timeout: nil, term_timeout: 0.1) }
      end
    end
    assert_equal [{ timeout: 0, term_timeout: 0.1, force: false }], calls
    assert session.to_io.closed?
  end

  def test_transcript_failure_closes_the_real_pty_without_killing_a_term_resistant_child
    session = child('trap("TERM") {}; trap("HUP") {}; puts "ready"; STDIN.gets; puts "tail"; loop { sleep 1 }',
                    raw: true)
    assert session.expect("ready", timeout: 2).matched?
    failure = IOError.new("disk full")
    session.transcript = write_target { raise failure }
    # 已收取初始提示，再触发真实 PTY 尾部输出，保证故障发生在读尾交付阶段。
    session.puts("emit")
    assert_same failure, assert_raises(IOError) { session.soft_close(timeout: 1, term_timeout: 0) }
    assert session.closed?
    assert session.to_io.closed?
    assert session.alive?
    refute_nil session.pid
    session.hard_close(timeout: 0)
    assert_nil session.pid
    assert_equal Signal.list.fetch("KILL"), session.process_status.termsig
  end

  def test_drain_error_survives_handle_and_logging_finalization_failures
    session, = pipe_session(own: true)
    primary = IOError.new("read failed first")
    session.redact("secret")
    session.transcript = write_target { raise "finish failed" }
    session.write_transcript("sec")
    session.to_io.stub(:wait_readable, ->(*) { raise primary }) do
      session.to_io.stub(:close, -> { raise IOError, "handle close failed" }) do
        assert_same primary, assert_raises(IOError) { session.soft_close(timeout: 1, term_timeout: 0) }
      end
    end
    # 失败句柄仍在账本，后续显式关闭可以重试。
    assert session.closed?
    refute session.to_io.closed?
    session.close
    assert session.to_io.closed?
  end

  def test_failed_drain_preserves_borrowed_handles
    session, = pipe_session
    primary = IOError.new("borrowed read failed")
    session.to_io.stub(:wait_readable, ->(*) { raise primary }) do
      assert_same primary, assert_raises(IOError) { session.soft_close(timeout: 1, term_timeout: 0) }
    end
    assert session.closed?
    refute session.to_io.closed?
  end

  def test_logger_delivery_failure_preserves_the_primary_exception
    session, producer = pipe_session(own: true)
    primary = RuntimeError.new("logger failed")
    session.logger = diagnostic_logger { raise primary }
    producer.write("tail")
    assert_same primary, assert_raises(RuntimeError) { session.soft_close(timeout: 1, term_timeout: 0) }
    assert session.closed?
    assert session.to_io.closed?
  end

  def test_nonlocal_exit_also_skips_unbounded_natural_wait
    session, = pipe_session(own: true)
    calls = []
    session.stub(:close_child, ->(**options) { calls << options }) do
      session.to_io.stub(:wait_readable, ->(*) { throw :stop, :returned }) do
        assert_equal :returned, catch(:stop) { session.soft_close(timeout: nil, term_timeout: 0) }
      end
    end
    assert_equal [{ timeout: 0, term_timeout: 0.0, force: false }], calls
    assert session.closed?
  end

  def test_interrupt_at_the_drain_block_return_cannot_start_an_unbounded_natural_wait
    session, = pipe_session(own: true)
    session.to_io.close
    primary = Interrupt.new("drain return interrupted")
    calls = []
    probe = TracePoint.new(:b_return) do |event|
      next unless event.method_id == :soft_close && event.defined_class == Expect::Session

      probe.disable
      raise primary
    end
    session.stub(:close_child, ->(**options) { calls << options }) do
      probe.enable do
        assert_same primary, assert_raises(Interrupt) { session.soft_close(timeout: nil, term_timeout: 0) }
      end
    end
    assert_equal [{ timeout: 0, term_timeout: 0.0, force: false }], calls
    assert session.closed?
  ensure
    probe&.disable
  end

  def test_thread_termination_at_the_drain_return_still_uses_finite_cleanup
    session, = pipe_session(own: true)
    session.to_io.close
    calls = []
    returned = Queue.new
    release = Queue.new
    probe = TracePoint.new(:b_return) do |event|
      next unless event.method_id == :soft_close && event.defined_class == Expect::Session

      probe.disable
      returned << true
      release.pop
    end
    session.stub(:close_child, ->(**options) { calls << options }) do
      worker = background do
        probe.enable { session.soft_close(timeout: nil, term_timeout: 0) }
      end
      bounded { returned.pop }
      worker.kill
      bounded { worker.join }
    end
    assert_equal [{ timeout: 0, term_timeout: 0.0, force: false }], calls
    assert session.closed?
  ensure
    probe&.disable
  end

  def test_invalid_arguments_do_not_start_closing
    session, = pipe_session(own: true)
    assert_raises(ArgumentError) { session.soft_close(timeout: -1) }
    assert_raises(ArgumentError) { session.soft_close(term_timeout: nil) }
    refute session.closed?
    refute session.to_io.closed?
  end
end
