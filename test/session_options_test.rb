# frozen_string_literal: true

require_relative "test_helper"

class SessionOptionsTest < ExpectTest
  def test_explicit_session_options_are_independent
    first, = pipe_session(timeout: 0.1, write_timeout: 2, buffer_limit: 4)
    second, = pipe_session(timeout: 0.1, buffer_limit: 4)
    first.timeout = 1
    first.buffer_limit = nil
    third, = pipe_session

    assert_equal 1, first.timeout
    assert_equal 0.1, second.timeout
    assert_nil third.timeout
    assert_equal 4, second.buffer_limit
    assert_nil first.buffer_limit
    assert_equal 2, first.write_timeout
    assert_nil second.write_timeout
  end

  def test_attribute_validation_preserves_the_current_value_and_buffer
    session, = pipe_session(buffer_limit: 8, timeout: 1, write_timeout: 2)
    session.buffer = "contents"
    [0, -1, 1.5, "4"].each do |limit|
      assert_raises(ArgumentError) { session.buffer_limit = limit }
    end
    assert_equal 8, session.buffer_limit
    assert_equal "contents", session.buffer
    assert_raises(ArgumentError) { session.timeout = Float::INFINITY }
    assert_raises(ArgumentError) { session.write_timeout = -1 }
    assert_equal [1, 2], [session.timeout, session.write_timeout]
    session.buffer_limit = 4
    assert_equal "ents", session.buffer
  end

  def test_consumption_policy_only_applies_to_one_wait
    session, = pipe_session
    session.buffer = "first second"
    result = session.expect("first", consume: false, timeout: 0)
    assert_equal "first", result.match
    assert_equal "first second", session.buffer
    assert session.expect("first", timeout: 0).matched?
    assert_equal " second", session.buffer
  end

  def test_operation_policies_are_not_session_configuration
    session, = pipe_session
    %i[raw_pty raw_terminal preserve_buffer reset_timeout_on_read graceful_close].each do |name|
      refute_respond_to session, name
      refute_respond_to session, :"#{name}?"
      refute_respond_to session, :"#{name}="
      assert_raises(ArgumentError) { Expect::Session.new(**{ name => true }) }
    end
    refute_respond_to Expect, :configure
    refute_respond_to Expect, :configuration
    refute_respond_to Expect, :new
    refute Expect.const_defined?(:Configuration, false)
  end

  def test_session_new_only_creates_a_pty_without_starting_a_process
    session = Expect::Session.new
    @sessions << session
    assert_instance_of Expect::Session, session
    assert_nil session.pid
    assert_nil session.command
    assert session.to_io.tty?
    assert_raises(ArgumentError) { Expect::Session.new("/bin/sh") }
  end

  def test_invalid_owned_io_options_release_endpoints
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    assert_raises(ArgumentError) { Expect.open(reader, own: true, timeout: -1) }
    assert reader.closed?
    refute writer.closed?
  end

  def test_allocation_failure_closes_owned_io_without_replacing_the_error
    assert_allocation_failure_cleanup(own: true)
  end

  def test_allocation_failure_preserves_borrowed_io_and_the_original_error
    assert_allocation_failure_cleanup(own: false)
  end

  private

  def assert_allocation_failure_cleanup(own:)
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    original = Interrupt.new("allocation interrupted")
    Expect::Session.stub(:allocate, -> { raise original }) do
      actual = assert_raises(Interrupt) { Expect.open(reader, writer:, own:) }
      assert_same original, actual
    end
    assert_equal own, reader.closed?
    assert_equal own, writer.closed?
  ensure
    # Minitest 恢复继承方法会留下单例包装；还原原生 Class#allocate 的查找链。
    Expect::Session.singleton_class.remove_method(:allocate)
  end
end
