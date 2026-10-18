# frozen_string_literal: true

require_relative "test_helper"

class SessionFactoryTest < ExpectTest
  def test_interruption_before_factory_entry_closes_owned_io
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    trace = TracePoint.new(:c_call) do |point|
      next unless point.method_id == :handle_interrupt && point.path.end_with?("/expect/pty.rb")

      trace.disable
      raise Interrupt, "before factory ownership handoff"
    end
    assert_raises(Interrupt) { trace.enable { Expect.open(reader, writer:, own: true) } }
    assert reader.closed?
    assert writer.closed?
  ensure
    trace&.disable
  end

  def test_factory_cleans_owned_io_when_construction_fails
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    factory = Expect.const_get(:SessionFactory, false)
    assert_raises(ArgumentError) { factory.io(reader, writer:, own: true, timeout: -1) }
    assert reader.closed?
    assert writer.closed?
  end

  def test_factory_does_not_close_borrowed_io_when_construction_fails
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    factory = Expect.const_get(:SessionFactory, false)
    assert_raises(ArgumentError) { factory.io(reader, writer:, own: false, timeout: -1) }
    refute reader.closed?
    refute writer.closed?
  end
end
