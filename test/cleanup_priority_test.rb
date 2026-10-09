# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class CleanupPriorityTest < ExpectTest
  def test_process_failure_survives_failing_log_finalization
    [RuntimeError.new("wait failed"), Interrupt.new("wait interrupted"), SystemExit.new(17)].each do |primary|
      %i[logger transcript].each do |channel|
        session = child("sleep 60", raw: true)
        prepare_pending_logs(session, channel => RuntimeError.new("log failed"))

        session.stub(:wait, ->(**) { raise primary }) do
          assert_same primary, assert_raises(primary.class) { session.hard_close(timeout: 0) }
        end
        assert session.closed?
        session.hard_close(timeout: 0)
        assert_nil session.pid
      end
    end
  end

  def test_handle_failure_survives_failing_log_finalization
    session, = pipe_session(own: true)
    failure = IOError.new("handle close failed")
    prepare_pending_logs(session, logger: RuntimeError.new("logger failed"))

    session.to_io.stub(:close, -> { raise failure }) do
      assert_same failure, assert_raises(IOError) { session.hard_close(timeout: 0) }
    end
    session.close
    assert session.to_io.closed?
  end

  def test_both_logs_are_attempted_and_the_first_failure_is_preserved
    session, = pipe_session
    failure = RuntimeError.new("logger failed first")
    calls = prepare_pending_logs(session, logger: failure, transcript: ArgumentError.new("transcript failed second"))

    assert_same failure, assert_raises(RuntimeError) { session.close }
    assert_equal %i[logger transcript], calls
    assert session.closed?
    assert_nil session.close
  end

  def test_new_fatal_log_failure_is_not_hidden_by_a_process_failure
    session = child("sleep 60", raw: true)
    failure = Interrupt.new("logger interrupted")
    calls = prepare_pending_logs(session, logger: failure, transcript: nil)

    session.stub(:wait, ->(**) { raise "wait failed" }) do
      assert_same failure, assert_raises(Interrupt) { session.hard_close(timeout: 0) }
    end
    assert_equal %i[logger transcript], calls
    session.hard_close(timeout: 0)
    assert_nil session.pid
  end

  private

  def prepare_pending_logs(session, failures)
    calls = []
    session.redact("secret")
    if failures.key?(:logger)
      session.logger = diagnostic_logger do
        calls << :logger
        raise failures[:logger] if failures[:logger]
      end
      session.__send__(:trace_data, :sending, "sec")
    end
    if failures.key?(:transcript)
      session.transcript = write_target do
        calls << :transcript
        raise failures[:transcript] if failures[:transcript]
      end
      session.write_transcript("sec")
    end
    calls
  end
end
