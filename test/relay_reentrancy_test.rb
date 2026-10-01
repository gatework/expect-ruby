# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class RelayReentrancyTest < ExpectTest
  def test_recursive_write_and_flush_cannot_duplicate_delivery_or_change_cursors
    %i[write flush].each do |entry|
      source, = pipe_session
      output = StringIO.new
      errors = []
      snapshots = []
      entered = false
      original = output.method(entry)
      output.define_singleton_method(entry) do |*arguments|
        result = original.call(*arguments)
        unless entered
          entered = true
          cursors = source.__send__(:pending_writes)
          snapshot = -> { [source.buffer, cursors.map { |c| c.instance_variable_get(:@offset) }] }
          snapshots << snapshot.call
          begin
            Expect.interconnect(source, timeout: 0)
          rescue StandardError => error
            errors << error
          end
          snapshots << snapshot.call
        end
        result
      end
      source.outputs = [output]
      source.buffer = "abc"
      bounded { Expect.interconnect(source, timeout: 0) }
      assert_equal "abc", output.string, "recursive #{entry} replayed bytes"
      assert_equal(["Expect::ReentrancyError"], errors.map { |error| error.class.name })
      assert_equal snapshots.first, snapshots.last
      refute source.pending_output?
    end
  end

  def test_escape_callback_cannot_enter_the_same_source_but_can_use_a_matcher
    source, = pipe_session
    output = StringIO.new
    source.outputs = [output]
    calls = 0
    source.on_sequence("!") do
      calls += 1
      error = assert_raises(StandardError) { Expect.interconnect(source, timeout: 0) }
      assert_equal "Expect::ReentrancyError", error.class.name
      assert_equal "inside", source.expect("inside", timeout: 0).match
      false
    end
    source.buffer = "prefix!insidetail"
    assert_same source, Expect.interconnect(source, timeout: 1)
    assert_equal 1, calls
    assert_equal "prefix", output.string
    assert_equal "tail", source.buffer
    Expect.interconnect(source, timeout: 0)
    assert_equal "prefixtail", output.string
  end

  def test_partial_overlap_does_not_steal_buffers_or_release_the_outer_owner
    outer, = pipe_session
    other, = pipe_session
    other.buffer = "other"
    output = StringIO.new
    other.outputs = [output]
    outer.on_sequence("!") do
      2.times do
        error = assert_raises(StandardError) { Expect.interconnect(other, outer, timeout: 0) }
        assert_equal "Expect::ReentrancyError", error.class.name
        assert_equal "other", other.buffer
      end
      Expect.interconnect(other, timeout: 0)
      false
    end
    outer.buffer = "!tail"
    assert_same outer, Expect.interconnect(outer, timeout: 1)
    assert_equal "tail", outer.buffer
    assert_equal "other", output.string
  end

  def test_disjoint_sources_and_duplicate_arguments_are_supported
    outer, = pipe_session
    inner, = pipe_session
    sink = StringIO.new
    inner.outputs = [sink]
    inner.buffer = "independent"
    outer.buffer = "!tail"
    outer.on_sequence("!") do
      Expect.interconnect(inner, inner, timeout: 0)
      false
    end
    assert_same outer, Expect.interconnect(outer, outer, timeout: 1)
    assert_equal "independent", sink.string
    assert_equal "tail", outer.buffer
  end

  def test_uncaught_reentry_propagates_and_sequential_retry_releases_the_owner
    source, = pipe_session
    sink = StringIO.new
    entered = false
    original = sink.method(:write)
    sink.define_singleton_method(:write) do |data|
      unless entered
        entered = true
        Expect.interconnect(source, timeout: 0)
      end
      original.call(data)
    end
    source.outputs = [sink]
    source.buffer = "once"
    error = assert_raises(StandardError) { Expect.interconnect(source, timeout: 0) }
    assert_equal "Expect::ReentrancyError", error.class.name
    assert source.pending_output?
    Expect.interconnect(source, timeout: 0)
    assert_equal "once", sink.string
    refute source.pending_output?
  end

  def test_preparation_failure_restores_all_moved_buffers_and_releases_ownership
    first, = pipe_session
    second, = pipe_session
    first.buffer = "first"
    second.buffer = "second"
    error = IOError.new("injected preparation failure")
    second.stub(:clear_buffer, -> { raise error }) do
      assert_same error, assert_raises(IOError) { Expect.interconnect(first, second, timeout: 0) }
    end
    assert_equal "first", first.buffer
    assert_equal "second", second.buffer
    sink = StringIO.new
    first.outputs = second.outputs = [sink]
    Expect.interconnect(first, second, timeout: 0)
    assert_equal "firstsecond", sink.string
  end

  def test_invalid_arguments_leave_buffers_unchanged
    source, = pipe_session
    source.buffer = "retained"
    assert_raises(ArgumentError) { Expect.interconnect(source, timeout: -1) }
    assert_raises(ArgumentError) { Expect.interconnect(source, Object.new, timeout: 0) }
    assert_equal "retained", source.buffer
    refute source.pending_output?
  end

  def test_eof_and_callback_errors_release_ownership
    source, producer = pipe_session
    failure = Interrupt.new("callback interrupted")
    source.on_sequence("!") { raise failure }
    source.buffer = "!tail"
    assert_same failure, assert_raises(Interrupt) { Expect.interconnect(source, timeout: 1) }
    producer.close
    sink = StringIO.new
    source.outputs = [sink]
    2.times { assert_same source, Expect.interconnect(source, timeout: 1) }
    assert_equal "tail", sink.string
  end
end
