# frozen_string_literal: true

require_relative "test_helper"

class BufferHandoffTest < ExpectTest
  def test_cancelled_relay_acquisition_returns_every_sources_input
    %i[raise kill].each do |cancellation|
      sources = Array.new(2) { pipe_session.first }
      sources.each { |source| source.buffer = "retained" }

      cancel_at_return(sources.last, :take_buffer, cancellation:) do
        Expect.interconnect(*sources, timeout: 0)
      end

      sources.each do |source|
        assert_equal "retained", source.buffer
        assert_nil source.interaction_buffer
        assert_nil source.relay_owner
      end
    end
  end

  def test_cancelled_matcher_acquisition_preserves_the_borrowed_buffer
    session, = pipe_session
    buffer = "nested tail".b
    session.interaction_buffer = buffer

    cancel_at_return(session, :interaction_buffer=) { session.expect("nested ", timeout: 0) }

    assert_same buffer, session.interaction_buffer
    assert_equal "nested tail", buffer
    assert_empty session.buffer
  end

  def test_cancelled_matcher_return_keeps_only_the_unconsumed_tail
    session, = pipe_session
    buffer = "nested tail".b
    session.interaction_buffer = buffer

    cancel_at_return(session, :take_buffer) { session.expect("nested ", timeout: 0) }

    assert_same buffer, session.interaction_buffer
    assert_equal "tail", buffer
    assert_empty session.buffer
  end

  def test_cancelled_relay_return_restores_all_sources_and_releases_ownership
    first, = pipe_session
    second, = pipe_session
    first.buffer = "STOPfirst"
    first.on_sequence("STOP")
    second.buffer = "second"

    cancel_at_return(first, :restore_relay_buffer) { Expect.interconnect(first, second, timeout: 1) }

    assert_equal "first", first.buffer
    assert_equal "second", second.buffer
    [first, second].each do |source|
      assert_nil source.interaction_buffer
      assert_nil source.relay_owner
    end
  end

  def test_relay_callbacks_remain_immediately_interruptible
    session, = pipe_session
    session.buffer = "!tail"
    session.on_sequence("!") do
      Thread.current.raise(Interrupt, "callback cancelled")
      flunk "relay callback deferred cancellation"
    end

    assert_raises(Interrupt) { Expect.interconnect(session, timeout: 0) }
    assert_equal "tail", session.buffer
    assert_nil session.relay_owner
  end

  def test_cancelled_nested_match_returns_the_tail_to_the_outer_relay_once
    session, = pipe_session
    output = StringIO.new
    session.outputs = [output]
    session.buffer = "!nested tail"
    session.on_sequence("!") { session.expect("nested ", timeout: 0) }

    cancel_at_return(session, :take_buffer, occurrence: 2) { Expect.interconnect(session, timeout: 0) }

    assert_equal "tail", session.buffer
    assert_nil session.interaction_buffer
    assert_nil session.relay_owner
    assert_empty output.string
    assert_nil Expect.interconnect(session, timeout: 0)
    assert_equal "tail", output.string
    assert_empty session.buffer
  end

  private

  # 暂停在返回值尚未登记的边界；先发出取消，再放行，屏蔽区必须完成登记后交付取消。
  def cancel_at_return(receiver, method, cancellation: :raise, occurrence: 1, &operation)
    arrived = Queue.new
    proceed = Queue.new
    calls = 0
    trace = TracePoint.new(:return, :c_return) do |event|
      next unless event.method_id == method && event.self.equal?(receiver)

      calls += 1
      next unless calls == occurrence

      trace.disable
      arrived << true
      proceed.pop
    end
    worker = background do
      trace.enable(target_thread: Thread.current, &operation)
    rescue Interrupt
      :cancelled
    end
    bounded { arrived.pop }
    cancellation == :raise ? worker.raise(Interrupt, "cancel buffer handoff") : worker.kill
    proceed << true
    assert(bounded { worker.join })
  ensure
    proceed << true
    trace&.disable
  end
end
