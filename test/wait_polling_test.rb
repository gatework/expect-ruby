# frozen_string_literal: true

require_relative "test_helper"

class WaitPollingTest < ExpectTest
  def test_child_wait_starts_with_one_millisecond_and_caps_backoff
    session = Expect::Session.new
    @sessions << session
    now = 0.0
    sleeps = []
    polls = 0
    finished = Object.new
    supervisor = session.instance_variable_get(:@child_process)
    supervisor.stub(:pid, 123) do
      supervisor.stub(:status, lambda {
        polls += 1
        finished if polls > 7
      }) do
        session.stub(:sleep, lambda { |period|
          sleeps << period
          now += period
        }) do
          Expect.stub(:monotonic, -> { now }) do
            assert_same finished, session.__send__(:wait_for_child, 1)
          end
        end
      end
    end
    assert_in_delta 0.001, sleeps.first, 0.000001
    assert(sleeps.all? { |period| period <= 0.01 })
    assert_operator sleeps[1], :>, sleeps[0]
  end

  def test_absent_logger_does_not_evaluate_diagnostic_message
    session, = pipe_session
    session.__send__(:trace) { flunk "diagnostic message evaluated without a logger" }
  end
end
