# frozen_string_literal: true

require_relative "test_helper"

class RelayRecoveryTest < ExpectTest
  def sink_session(**)
    reader, peer = IO.pipe
    sink, writer = IO.pipe
    @ios.push(reader, peer, sink, writer)
    session = Expect.open(reader, writer:, **)
    @sessions << session
    [session, sink, peer]
  end

  def fill(writer)
    total = 0
    loop do
      count = writer.write_nonblock("x" * 4096, exception: false)
      return total if count == :wait_writable

      total += count
    end
  end

  def drain(reader)
    data = "".b
    loop do
      chunk = reader.read_nonblock(65_536, exception: false)
      return data if chunk == :wait_readable || chunk.nil?

      data << chunk
    end
  end

  def test_outer_deadline_bounds_raw_io_and_expect_listeners
    [false, true].each do |wrapped|
      source, = pipe_session
      target, = sink_session
      fill(target.writer)
      source.listeners = [wrapped ? target : target.writer]
      source.buffer = "request"
      started = Expect.monotonic
      assert_nil bounded(0.5) { Expect.interconnect(source, target, timeout: 0.02) }
      assert_operator Expect.monotonic - started, :<, 0.3
    end
  end

  def test_distinct_writers_with_equal_values_remain_independent_wait_targets
    source, = pipe_session
    stopper, producer = pipe_session
    stopper.on_sequence("!")
    first, = sink_session
    second, sink = sink_session
    fill(first.writer)
    filled = fill(second.writer)
    [first.writer, second.writer].each do |io|
      io.define_singleton_method(:hash) { 0 }
      io.define_singleton_method(:eql?) { |other| other.is_a?(IO) }
    end
    source.listeners = [first.writer, second.writer]
    source.buffer = "request"
    selecting = Queue.new
    original = IO.method(:select)
    select = lambda do |*arguments|
      selecting << true
      original.call(*arguments)
    end
    receiver = background do
      selecting.pop
      sink.read(filled)
      received = sink.read(7)
      producer.write("!")
      received
    end

    IO.stub(:select, select) do
      assert_same(stopper, bounded { Expect.interconnect(source, stopper, timeout: 1) })
    end
    assert receiver.join(1), "receiver did not finish"
    assert_equal "request", receiver.value
    assert source.pending_output?
  end

  def test_partial_timeout_and_retry_deliver_exactly_once_to_each_listener
    source, source_writer = pipe_session
    target, sink = sink_session(write_timeout: 0.02)
    first = StringIO.new
    source.listeners = [first, target]
    payload = (0..255).to_a.pack("C*") * 2048
    source.buffer = payload
    assert_raises(Expect::WriteTimeout) { bounded { Expect.interconnect(source, timeout: 1) } }
    received = drain(sink)
    assert_operator received.bytesize, :>, 0
    assert_operator received.bytesize, :<, payload.bytesize
    target.write_timeout = 2
    receiver = background do
      loop { received << sink.readpartial(65_536) }
    rescue EOFError
      received
    end
    source_writer.close
    assert_same(source, bounded { Expect.interconnect(source, timeout: 2) })
    target.writer.close
    assert receiver.join(2), "receiver did not finish"
    assert_equal payload.bytesize, receiver.value.bytesize
    assert payload == receiver.value, "resumed pipe output differs from the original bytes"
    assert_equal payload.bytesize, first.string.bytesize
    assert payload == first.string.b, "first listener output differs from the original bytes"
  end

  def test_short_custom_writes_preserve_suffix
    source, = pipe_session
    received = "".b
    target = Object.new
    target.define_singleton_method(:write) do |data|
      count = [2, data.bytesize].min
      received << data.byteslice(0, count)
      count
    end
    source.listeners = [target]
    source.buffer = "abcdef"
    Expect.interconnect(source, timeout: 0.02)
    assert_equal "abcdef", received
  end

  def test_failed_second_listener_does_not_replay_first_listener
    source, = pipe_session
    first = StringIO.new
    second = StringIO.new
    failing = true
    original = second.method(:write)
    second.define_singleton_method(:write) do |data|
      raise IOError, "listener failed" if failing

      original.call(data)
    end
    source.listeners = [first, second]
    source.buffer = "payload"
    assert_raises(IOError) { Expect.interconnect(source, timeout: 0.02) }
    failing = false
    Expect.interconnect(source, timeout: 0.02)
    assert_equal "payload", first.string
    assert_equal "payload", second.string
  end

  def test_repeated_interact_with_raw_input_keeps_read_ahead
    session, sink = sink_session
    input, keyboard = IO.pipe
    @ios.push(input, keyboard)
    keyboard.write("one!two!")
    first = session.interact(input:, output: StringIO.new, escape: "!", timeout: 0.05)
    second = session.interact(input:, output: StringIO.new, escape: "!", timeout: 0.05)
    assert_same first, second
    assert_equal "onetwo", drain(sink)
    refute input.closed?
  end

  def test_write_retries_read_eintr_during_backpressure
    session, sink, peer = sink_session(write_timeout: 1)
    fill(session.writer)
    peer.write("reply")
    original = session.to_io.method(:read_nonblock)
    interrupted = false
    session.to_io.define_singleton_method(:read_nonblock) do |*args, **kwargs|
      unless interrupted
        interrupted = true
        raise Errno::EINTR
      end
      original.call(*args, **kwargs)
    end
    session.log_to { drain(sink) }
    assert_equal(5, bounded { session.write("hello") })
    assert interrupted
    assert_equal "reply", session.buffer
    assert_equal "hello", drain(sink)
  end

  def test_write_timeout_reports_accepted_bytes
    session, sink = sink_session(write_timeout: 0.02)
    error = assert_raises(Expect::WriteTimeout) { session.write("x" * 524_288) }
    received = drain(sink)
    assert_operator received.bytesize, :>, 0
    assert_equal received.bytesize, error.bytes_written
  end

  def test_nested_output_timeout_preserves_the_callers_write_progress
    %i[listeners log_output].each do |destination|
      session, sink, peer = sink_session(write_timeout: 1)
      target, = sink_session(write_timeout: 0)
      fill(target.writer)
      session.public_send(:"#{destination}=", destination == :listeners ? [target] : target)
      peer.write("reply")

      error = assert_raises(Expect::WriteTimeout) { bounded { session.write("x" * 1_048_576) } }
      received = drain(sink)
      assert_operator received.bytesize, :>, 0
      assert_equal received.bytesize, error.bytes_written
      assert_instance_of Expect::WriteTimeout, error.cause
      assert_equal 0, error.cause.bytes_written
      assert_equal "reply", session.buffer
    end
  end

  def test_truncated_utf8_at_eof_raises_without_losing_bytes
    session, writer = pipe_session
    writer.write("\xe4".b)
    writer.close
    assert_raises(EncodingError) { session.expect(/中/u, timeout: 1).number }
    assert_equal "\xe4".b, session.buffer
    assert_equal 1, session.expect("\xe4".b, timeout: 0).number
  end

  def test_blocked_target_does_not_starve_another_source
    slow, = pipe_session
    fast, writer = pipe_session
    target, = sink_session
    fill(target.writer)
    slow.listeners = [target]
    slow.buffer = "blocked"
    output = StringIO.new
    fast.listeners = [output]
    writer.write("ready")
    assert_nil bounded(0.5) { Expect.interconnect(slow, fast, timeout: 0.02) }
    assert_equal "ready", output.string
    assert slow.pending_output?
  end

  def test_outer_timeout_keeps_output_for_original_targets
    source, = pipe_session
    target, sink = sink_session
    fill(target.writer)
    source.listeners = [target.writer]
    source.buffer = "request"
    Expect.interconnect(source, timeout: 0.01)
    assert source.pending_output?
    assert_empty source.buffer
    drain(sink)
    replacement = StringIO.new
    source.listeners = [replacement]
    source.buffer = "new"
    Expect.interconnect(source, timeout: 0.02)
    refute source.pending_output?
    assert_equal "request", drain(sink)
    assert_equal "new", replacement.string
  end

  def test_every_short_write_failure_position_resumes_without_replay
    0.upto(5) do |failure_offset|
      source, = pipe_session
      first = StringIO.new
      received = "".b
      failed = false
      target = Object.new
      target.define_singleton_method(:write) do |data|
        if !failed && received.bytesize == failure_offset
          failed = true
          raise IOError, "interrupted delivery"
        end
        received << data.byteslice(0, 1)
        1
      end
      source.listeners = [first, target]
      source.buffer = "abcdef"
      assert_raises(IOError) { Expect.interconnect(source, timeout: 1) }
      assert source.pending_output?
      Expect.interconnect(source, timeout: 0.01)
      assert_equal "abcdef", received
      assert_equal "abcdef", first.string
      refute source.pending_output?
    end
  end

  def test_split_literal_and_short_write_failures_preserve_delivery_and_callback_order
    [1, 2, 3].product([1, 2, 3], [0, 2]).each do |split, step, failure_offset|
      source, writer = pipe_session
      fast = StringIO.new
      received = "".b
      failed = false
      slow = Object.new
      slow.define_singleton_method(:write) do |data|
        if !failed && received.bytesize == failure_offset
          failed = true
          raise IOError, "injected partial delivery"
        end
        count = [step, data.bytesize].min
        count = [count, failure_offset - received.bytesize].min unless failed
        received << data.byteslice(0, count)
        count
      end
      callbacks = []
      source.listeners = [fast, slow]
      source.on_sequence("STOP") do
        callbacks << [fast.string.dup, received.dup]
        false
      end
      source.buffer = "head#{"STOP".byteslice(0, split)}"
      writer.write("#{"STOP".byteslice(split..)}tail")
      assert_raises(IOError) { bounded { Expect.interconnect(source, timeout: 1) } }
      assert_empty callbacks
      assert source.pending_output?
      assert_same(source, bounded { Expect.interconnect(source, timeout: 1) })
      assert_equal [%w[head head]], callbacks
      assert_equal "tail", source.buffer
      assert_equal "head", fast.string
      assert_equal "head", received
      refute source.pending_output?
    end
  end

  def test_flush_failure_retries_flush_without_replaying_data
    source, = pipe_session
    output = StringIO.new
    failed = false
    output.define_singleton_method(:flush) do
      return if failed

      failed = true
      raise IOError, "flush failed"
    end
    source.listeners = [output]
    source.buffer = "once"
    assert_raises(IOError) { Expect.interconnect(source, timeout: 1) }
    Expect.interconnect(source, timeout: 0.01)
    assert_equal "once", output.string
    refute source.pending_output?
  end

  def test_invalid_write_count_raises_and_can_recover
    [0, nil, -1, 7, "6", :wait_writable].each do |invalid|
      source, = pipe_session
      output = StringIO.new
      source.listeners = [output]
      source.buffer = "abcdef"
      output.stub(:write, invalid) do
        assert_raises(IOError) { bounded { Expect.interconnect(source, timeout: 1) } }
      end
      Expect.interconnect(source, timeout: 0.01)
      assert_equal "abcdef", output.string
    end
  end

  def test_escape_callback_waits_for_prefix_delivery_across_timeout
    source, = pipe_session
    target, sink = sink_session
    fill(target.writer)
    source.listeners = [target]
    called = 0
    source.on_sequence(/END\z/) do
      called += 1
      false
    end
    source.buffer = "prefixEND"
    assert_nil Expect.interconnect(source, timeout: 0.01)
    assert_equal 0, called
    source.buffer = "tail"
    drain(sink)
    assert_same source, Expect.interconnect(source, timeout: 0.1)
    assert_equal 1, called
    assert_equal "prefix", drain(sink)
    assert_equal "tail", source.buffer
  end

  def test_matching_window_does_not_truncate_undelivered_relay_input
    source, writer = pipe_session(buffer_limit: 2)
    target, sink = sink_session
    fill(target.writer)
    source.listeners = [target]
    source.on_sequence("!")
    writer.write("prefix!tail")
    Expect.interconnect(source, timeout: 0.01)
    assert_equal "tail", source.buffer
    drain(sink)
    assert_same source, Expect.interconnect(source, timeout: 0.1)
    assert_equal "prefix", drain(sink)
    assert_equal "tail", source.buffer
  end

  def test_unlisted_target_output_is_drained_without_losing_bytes
    source, writer = pipe_session
    target = child('puts "ready"; data = STDIN.read(131072); print "reply" if data.bytesize == 131072',
                   raw_pty: true, write_timeout: 1)
    source.listeners = [target]
    source.buffer = "x" * 131_072
    writer.close
    assert_same(source, bounded { Expect.interconnect(source, timeout: 2) })
    refute source.pending_output?
    assert_empty source.buffer
    assert_equal 1, target.expect("ready", timeout: 1).number
    assert_equal 1, target.expect("reply", timeout: 1).number
  end

  def test_eof_validates_truncated_utf8_in_escape_regex
    source, writer = pipe_session
    source.on_sequence(/中/u)
    writer.write("\xe4".b)
    writer.close
    assert_raises(EncodingError) { Expect.interconnect(source, timeout: 1) }
  end

  def test_instance_regexp_timeout_propagates_and_keeps_buffer
    source, = pipe_session
    source.buffer = "#{"a" * 30}!"
    regexp = Regexp.new('\\A(a+)+\\1\\z', timeout: 0.01)
    global_timeout = Regexp.timeout
    assert_raises(Regexp::TimeoutError) { bounded { source.expect(regexp, timeout: 0).number } }
    assert_equal "#{"a" * 30}!", source.buffer
    assert Regexp.timeout == global_timeout, "matching must not change the process regexp timeout"
    assert_equal 0.01, regexp.timeout
  end

  def test_closed_cached_input_wrapper_can_be_reopened_without_closing_raw_io
    session, sink = sink_session
    input, keyboard = IO.pipe
    @ios.push(input, keyboard)
    keyboard.write("one!")
    source = session.interact(input:, output: StringIO.new, escape: "!", timeout: 0.1)
    source.close
    keyboard.write("two!")
    resumed = session.interact(input:, output: StringIO.new, escape: "!", timeout: 0.1)
    refute_same source, resumed
    assert_equal "onetwo", drain(sink)
    resumed.graceful_close = true
    bounded(0.5) { session.close }
    assert resumed.closed?
    refute input.closed?
  end

  def test_repeated_read_interruptions_do_not_extend_write_timeout
    session, = sink_session(write_timeout: 0.02)
    fill(session.writer)
    reads = 0
    session.to_io.stub(:read_nonblock, lambda { |*|
      reads += 1
      raise Errno::EINTR
    }) do
      IO.stub(:select, ->(*) { [[session.to_io], [], []] }) do
        error = assert_raises(Expect::WriteTimeout) { bounded(0.5) { session.write("request") } }
        assert_equal 0, error.bytes_written
      end
    end
    assert_operator reads, :>, 1
  end

  def test_zero_timeout_retains_a_blocked_escape_prefix_for_retry
    source, = pipe_session
    target, sink = sink_session
    fill(target.writer)
    source.on_sequence("STOP")
    source.listeners = [target]
    source.buffer = "ST"
    assert_nil bounded(0.5) { Expect.interconnect(source, timeout: 0) }
    assert source.pending_output?
    drain(sink)
    Expect.interconnect(source, timeout: 0.01)
    assert_equal "ST", drain(sink)
    refute source.pending_output?
  end

  def test_short_log_writes_keep_all_bytes
    source, = pipe_session
    output = StringIO.new
    original = output.method(:write)
    output.define_singleton_method(:write) { |data| original.call(data.byteslice(0, 1)) }
    source.log_to(output)
    source.write_log("complete")
    assert_equal "complete", output.string
  end

  def test_interrupted_custom_output_is_retried_without_waiting_for_new_input
    source, = pipe_session
    output = StringIO.new
    interrupted = false
    original = output.method(:write)
    output.define_singleton_method(:write) do |data|
      unless interrupted
        interrupted = true
        raise Errno::EINTR
      end
      original.call(data)
    end
    source.listeners = [output]
    source.on_sequence("!")
    source.buffer = "ready!"
    assert_same source, bounded(0.5) { Expect.interconnect(source, timeout: 0.05) }
    assert_equal "ready", output.string
  end
end
