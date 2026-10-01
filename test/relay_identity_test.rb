# frozen_string_literal: true

require_relative "test_helper"

class RelayIdentityTest < ExpectTest
  def test_value_equal_sessions_keep_independent_queued_bytes_and_outputs
    first, = pipe_session
    second, = pipe_session
    equalize_sessions(first, second)
    outputs = [StringIO.new, StringIO.new]
    [first, second].each_with_index do |session, index|
      session.buffer = "source#{index}"
      session.outputs = [outputs[index]]
    end

    assert_nil Expect.interconnect(first, second, first, timeout: 0)
    assert_equal %w[source0 source1], outputs.map(&:string)
    assert_empty first.buffer
    assert_empty second.buffer
  end

  def test_continuing_equal_session_eof_does_not_remove_another_live_source
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    equalize_sessions(first, second)
    first_writer.close
    assert_nil first.read_available
    first.on_sequence(:eof) { true }
    second.on_sequence("!")
    second_writer.write("!tail")

    assert_same second, Expect.interconnect(first, second, timeout: 1)
    assert_equal "tail", second.buffer
    refute second.eof?
  end

  def test_equal_target_does_not_disable_an_unrelated_sources_backpressure
    source, producer = pipe_session
    other, = pipe_session
    sink, writer = IO.pipe
    @ios.push(sink, writer)
    target, = pipe_session(writer:)
    equalize_sessions(source, target)
    loop { break if writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    source.outputs = [writer]
    other.outputs = [target]
    source.buffer = "first"
    other.buffer = "second"
    producer.write("unread")

    assert_nil Expect.interconnect(source, other, timeout: 0)
    assert source.pending_output?
    assert_empty source.buffer
    assert_equal "unread", source.to_io.read_nonblock(100)
  end
end
