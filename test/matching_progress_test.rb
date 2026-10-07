# frozen_string_literal: true

require_relative "test_helper"

class MatchingProgressTest < ExpectTest
  def test_identical_input_read_by_a_nested_match_can_match_again
    [true, false].each do |consume|
      session, writer = pipe_session
      writer.write("ready")
      calls = 0

      result = bounded do
        session.expect(timeout: 0.05, consume:) do |patterns|
          patterns.on("ready") do |source|
            calls += 1
            if calls == 1
              source.clear_buffer unless consume
              writer.write("ready")
              assert source.expect("ready", timeout: 0, consume: false).matched?
              Expect.continue
            end
          end
        end
      end

      assert result.matched?, "new input was stalled with consume=#{consume}"
      assert_equal 2, calls
      assert_equal consume ? "" : "ready", session.buffer
    end
  end

  def test_another_callback_can_resume_a_stalled_pattern_with_identical_input
    session, writer = pipe_session
    session.buffer = "ready"
    events = []

    result = bounded do
      session.expect(timeout: 0.05, consume: false) do |patterns|
        patterns.on(/ready/) do
          events << :first
          Expect.continue if events.size == 1
        end
        patterns.on("ready") do |source|
          events << :second
          source.clear_buffer
          writer.write("ready")
          assert source.expect("ready", timeout: 0, consume: false).matched?
          Expect.continue
        end
      end
    end

    assert result.matched?
    assert_equal %i[first second first], events
  end

  def test_timeout_callback_can_resume_a_stalled_pattern_with_identical_input
    session, writer = pipe_session
    session.buffer = "ready"
    calls = timeouts = 0

    result = bounded do
      session.expect(timeout: 0, consume: false) do |patterns|
        patterns.on("ready") do
          calls += 1
          Expect.continue if calls == 1
        end
        patterns.timeout do
          timeouts += 1
          if timeouts == 1
            session.clear_buffer
            writer.write("ready")
            assert session.expect("ready", timeout: 0, consume: false).matched?
            Expect.continue
          end
        end
      end
    end

    assert result.matched?
    assert_equal 2, calls
    assert_equal 1, timeouts
  end

  def test_replacing_identical_bytes_does_not_count_as_input_progress
    [["ready", true], ["ready", false], [/(?=ready)/, true]].each do |pattern, consume|
      session, = pipe_session
      session.buffer = "ready"
      calls = 0

      result = bounded do
        session.expect(timeout: 0, consume:) do |patterns|
          patterns.on(pattern) do |source|
            calls += 1
            source.buffer = "ready"
            Expect.continue
          end
        end
      end

      assert result.timeout?
      assert_equal 1, calls
      assert_equal "ready", session.buffer
    end
  end

  def test_nested_poll_without_input_does_not_resume_a_stalled_pattern
    session, = pipe_session
    session.buffer = "ready"
    calls = 0

    result = bounded do
      session.expect(timeout: 0, consume: false) do |patterns|
        patterns.on("ready") do |source|
          calls += 1
          assert source.expect("missing", timeout: 0).timeout?
          Expect.continue
        end
      end
    end

    assert result.timeout?
    assert_equal 1, calls
  end
end
