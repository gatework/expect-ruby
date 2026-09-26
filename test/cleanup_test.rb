# frozen_string_literal: true

require_relative "test_helper"

class CleanupTest < ExpectTest
  def test_close_handles_attempts_every_owned_handle_and_preserves_first_error
    reader, writer = IO.pipe
    extra, peer = IO.pipe
    @ios.push(reader, writer, extra, peer)
    resources = Expect::SessionResources.new(reader, writer: writer, slave: extra, own: true)
    failure = IOError.new("reader close failed")
    reader.stub(:close, -> { raise failure }) do
      assert_same failure, assert_raises(IOError) { resources.close_handles }
      assert writer.closed?
      assert extra.closed?
    end
    resources.close_handles
    assert reader.closed?
    resources.close_handles
  end

  def test_hard_close_finishes_wrappers_log_and_child_after_handle_failure
    session = stubborn_child
    pid = session.pid
    first, = pipe_session
    second, = pipe_session
    session.instance_variable_set(:@interact_inputs, { first.to_io => first, second.to_io => second })
    Dir.mktmpdir do |dir|
      log = session.log_to(File.join(dir, "owned.log"))
      failure = IOError.new("handle close failed")
      session.to_io.stub(:close, -> { raise failure }) do
        first.stub(:close, ->(**) { raise IOError, "wrapper close failed" }) do
          error = assert_raises(IOError) { bounded { session.hard_close(timeout: 0.01) } }
          assert_same failure, error
          assert second.closed?
          refute second.to_io.closed?, "borrowed wrapper IO must remain open"
          assert log.closed?
          assert_nil session.log_output
          assert_nil session.pid
          assert_equal Signal.list.fetch("KILL"), session.process_status.termsig
          assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
        end
      end
    end
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_owned_log_close_failure_is_visible_after_child_reaping_and_retryable
    session = stubborn_child
    Dir.mktmpdir do |dir|
      log = session.log_to(File.join(dir, "owned.log"))
      log.stub(:close, -> { raise IOError, "log close failed" }) do
        assert_raises(IOError) { bounded { session.hard_close(timeout: 0.01) } }
        assert_nil session.pid
        assert_same log, session.log_output
      end
      status = session.hard_close(timeout: 0)
      assert_same session.process_status, status
      assert log.closed?
      assert_nil session.log_output
    end
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_explicit_close_inside_rescue_does_not_hide_a_new_cleanup_error
    session, = pipe_session(own: true)
    failure = IOError.new("close failed inside caller rescue")
    begin
      raise ArgumentError, "already handled"
    rescue ArgumentError
      session.to_io.stub(:close, -> { raise failure }) do
        assert_same failure, assert_raises(IOError) { session.hard_close(timeout: 0) }
      end
    end
  end

  def test_unexpected_process_error_is_not_replaced_by_cleanup_failure
    session = stubborn_child
    failure = RuntimeError.new("process wait failed")
    session.to_io.stub(:close, -> { raise IOError, "close failed" }) do
      session.stub(:wait, ->(**) { raise failure }) do
        assert_same failure, assert_raises(RuntimeError) { session.hard_close(timeout: 0) }
      end
    end
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_soft_close_handle_failure_still_sends_term_but_never_kill
    session = stubborn_child
    signals = []
    original = Process.method(:kill)
    Process.stub(:kill, lambda { |signal, pid|
      signals << signal
      original.call(signal, pid)
    }) do
      session.to_io.stub(:close, -> { raise Errno::EIO, "close failed" }) do
        assert_raises(Errno::EIO) { bounded { session.soft_close(timeout: 0, term_timeout: 0) } }
      end
    end
    assert_equal ["TERM"], signals
    assert session.alive?
    assert session.closed?
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_finalizer_reaps_after_both_handle_and_log_close_fail
    session = stubborn_child
    pid = session.pid
    resources = session.instance_variable_get(:@resources)
    log_attempted = false
    Dir.mktmpdir do |dir|
      log = session.log_to(File.join(dir, "owned.log"))
      session.to_io.stub(:close, -> { raise IOError, "handle failed" }) do
        log.stub(:close, lambda {
          log_attempted = true
          raise Errno::EIO, "log failed"
        }) do
          bounded { resources.finalize }
        end
      end
      assert log_attempted
      assert_nil resources.pid
      bounded do
        loop do
          Process.kill(0, pid)
          sleep 0.005
        rescue Errno::ESRCH
          break
        end
      end
    end
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_non_owner_cleanup_never_signals_and_finalizer_leaves_handles_alone
    session = stubborn_child
    resources = session.instance_variable_get(:@resources)
    Process.stub(:pid, -1) do
      Process.stub(:kill, ->(*) { flunk "non-owner sent a signal" }) do
        resources.finalize
        refute session.to_io.closed?
        assert_nil session.hard_close(timeout: 0)
      end
    end
    assert session.alive?
  ensure
    session&.hard_close(timeout: 0)
  end

  private

  def stubborn_child
    session = child('Signal.trap("HUP", "IGNORE"); Signal.trap("TERM", "IGNORE"); puts "ready"; sleep 60',
                    raw_pty: true)
    assert_equal 1, session.expect("ready", timeout: 2)
    session
  end
end
