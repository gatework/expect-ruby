# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < ExpectTest
  def test_configuration_is_frozen_and_sessions_have_independent_settings
    Expect.configure(timeout: 0.1) do |config|
      config.buffer_limit = 4
      config.log_stdout = false
    end
    first, = pipe_session
    second, = pipe_session
    first.timeout = 1
    first.buffer_limit = nil
    Expect.configure(timeout: 2)
    third, = pipe_session

    assert_equal 1, first.timeout
    assert_equal 0.1, second.timeout
    assert_equal 2, third.timeout
    assert_equal 4, second.buffer_limit
    assert_nil first.buffer_limit
    assert_equal 2, Expect.configuration.timeout
    assert_raises(FrozenError) { Expect.configuration.timeout = 10 }
    Expect.configuration.to_h.clear
    assert_equal 2, Expect.configuration.timeout
  end

  def test_configuration_errors_do_not_publish_partial_changes
    previous = Expect.configuration
    assert_raises(ArgumentError) { Expect.configure(unknown: true) }
    assert_same previous, Expect.configuration
    assert_raises(ArgumentError) do
      Expect.configure do |config|
        config.timeout = 5
        config.debug_level = 4
      end
    end
    assert_same previous, Expect.configuration
    assert_raises(RuntimeError) { Expect.configure(timeout: 3) { raise "cancelled" } }
    assert_same previous, Expect.configuration
  end

  def test_subclasses_inherit_configuration_and_can_override_it_independently
    subclass = Class.new(Expect)
    Expect.configure(timeout: 0.5)
    assert_equal 0.5, subclass.configuration.timeout
    subclass.configure(timeout: 1)
    Expect.configure(timeout: 2)
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    subclass.open(reader) do |session|
      assert_equal 1, session.timeout
      assert_instance_of subclass, session
    end
    assert_equal 2, Expect.configuration.timeout
  end

  def test_concurrent_configure_updates_are_serialized
    subclass = Class.new(Expect)
    entered = Queue.new
    second_started = Queue.new
    release = Queue.new
    first = Thread.new do
      subclass.configure do |config|
        entered << true
        release.pop
        config.timeout = 1
      end
    end
    entered.pop
    second = Thread.new do
      second_started << true
      subclass.configure(debug_level: 2)
    end
    second_started.pop
    # 第一轮尚未发布时，第二轮不能从同一旧快照完成更新。
    refute second.join(0.05), "concurrent configure published before the first update finished"
    release << true
    first.value
    second.value
    assert_equal 1, subclass.configuration.timeout
    assert_equal 2, subclass.configuration.debug_level
  ensure
    release&.push(true)
    first&.join
    second&.join
  end

  def test_nested_configure_fails_without_publishing_partial_changes
    subclass = Class.new(Expect)
    previous = subclass.configuration
    assert_raises(ThreadError) do
      subclass.configure do |config|
        config.timeout = 1
        subclass.configure(debug_level: 2)
      end
    end
    assert_same previous, subclass.configuration
  end

  def test_attribute_validation_preserves_the_current_value_and_buffer
    session, = pipe_session(buffer_limit: 8, timeout: 1, write_timeout: 2, debug_level: 1)
    session.buffer = "contents"
    [0, -1, 1.5, "4"].each do |limit|
      assert_raises(ArgumentError) { session.buffer_limit = limit }
    end
    assert_equal 8, session.buffer_limit
    assert_equal "contents", session.buffer
    assert_raises(ArgumentError) { session.timeout = Float::INFINITY }
    assert_raises(ArgumentError) { session.write_timeout = -1 }
    assert_raises(ArgumentError) { session.debug_level = 1.5 }
    assert_equal [1, 2, 1], [session.timeout, session.write_timeout, session.debug_level]
    session.buffer_limit = 4
    assert_equal "ents", session.buffer
  end

  def test_predicates_use_ruby_truthiness_and_normalize_boolean_attributes
    Expect.configure(raw_pty: 0, log_stdout: nil)
    config = Expect.configuration
    assert_equal true, config.raw_pty?
    assert_equal false, config.log_stdout?
    session, = pipe_session
    assert session.raw_pty?
    refute session.log_stdout?
    session.preserve_buffer = 0
    assert session.preserve_buffer?
    session.preserve_buffer = nil
    refute session.preserve_buffer?
    assert_raises(ArgumentError) { session.timeout(1) }
    assert_raises(NoMethodError) { session.log_stdout(true) }
  end
end
