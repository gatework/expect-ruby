# frozen_string_literal: true

require_relative "test_helper"

class InterconnectTest < ExpectTest
  def test_distinct_readers_with_equal_values_remain_independent_sources
    first, = pipe_session
    second, writer = pipe_session
    [first.to_io, second.to_io].each do |io|
      io.define_singleton_method(:hash) { 0 }
      io.define_singleton_method(:eql?) { |other| other.is_a?(IO) }
    end
    second.on_sequence("!")
    writer.write("!tail")

    assert_same second, Expect.interconnect(first, second, timeout: 0.05)
    assert_equal "tail", second.buffer
    assert_empty first.buffer
  end

  def test_ready_io_equality_does_not_read_an_unselected_source
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    second.to_io.define_singleton_method(:==) { |other| other.is_a?(IO) }
    first.on_sequence("!")
    second.on_sequence("!")
    second_writer.write("!second")
    original = IO.method(:select)
    select = lambda do |*arguments|
      ready = original.call(*arguments)
      first_writer.write("!first")
      ready
    end

    IO.stub(:select, select) do
      assert_same second, Expect.interconnect(first, second, timeout: 0.05)
    end
    assert_equal "second", second.buffer
    assert_equal "!first", first.to_io.read_nonblock(100)
  end

  def test_ready_batch_preserves_source_order_with_equal_io_values
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    order = []
    outputs = [StringIO.new, StringIO.new]
    [first, second].each_with_index do |session, index|
      session.to_io.define_singleton_method(:hash) { 0 }
      session.to_io.define_singleton_method(:eql?) { |other| other.is_a?(IO) }
      session.log_to { order << index }
      session.listeners = [outputs[index]]
    end
    first_writer.write("first")
    second_writer.write("second")
    original = IO.method(:select)
    select = lambda do |*arguments|
      ready = original.call(*arguments)
      ready[0].reverse! if ready
      ready
    end

    IO.stub(:select, select) { assert_nil Expect.interconnect(first, second, timeout: 0) }
    assert_equal [0, 1], order
    assert_equal %w[first second], outputs.map(&:string)
  end

  def test_escape_callback_can_match_new_input_and_return_its_tail
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    result = nil
    session.on_sequence("!") do
      writer.write("ready tail")
      result = session.expect("ready", timeout: 0.05).number
      false
    end
    session.buffer = "!"

    assert_same(session, bounded { Expect.interconnect(session, timeout: 1) })
    assert_equal 1, result
    assert_equal " tail", session.buffer
    assert_empty output.string
    Expect.interconnect(session, timeout: 0)
    assert_equal " tail", output.string
  end

  def test_escape_callback_can_match_previously_read_tail
    session, = pipe_session
    result = nil
    session.on_sequence("!") do
      result = session.expect("ready", timeout: 0).number
      false
    end
    session.buffer = "!ready tail"

    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal 1, result
    assert_equal " tail", session.buffer
  end

  def test_callback_match_failure_returns_unconsumed_bytes_to_relay
    session, writer = pipe_session
    session.on_sequence("!") do
      writer.write("\xff".b)
      session.expect(/ready/u, timeout: 0.05).number
    end
    session.buffer = "!prefix"

    assert_raises(EncodingError) { bounded { Expect.interconnect(session, timeout: 1) } }
    assert_equal "prefix\xff".b, session.buffer
    assert_nil session.__send__(:session).__send__(:interaction_buffer)
  end

  def test_timeout_flush_leaves_blocked_output_pending_without_reading_after_deadline
    reader, writer = IO.pipe
    sink, sink_writer = IO.pipe
    @ios.push(reader, writer, sink, sink_writer)
    loop { break if sink_writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    session = Expect.open(reader, writer: sink_writer, write_timeout: 1)
    @sessions << session
    # A loopback listener must not wait or read more input after the deadline.
    session.listeners = [session]
    session.on_sequence("STOP")
    session.buffer = "ST"
    writer.write("tail")
    original = IO.method(:select)
    poll = true
    select = lambda do |*arguments|
      if poll
        poll = false
        nil
      else
        original.call(*arguments)
      end
    end

    IO.stub(:select, select) { assert_nil Expect.interconnect(session, timeout: 0) }
    assert session.pending_output?
    assert_empty session.buffer
    session.listeners = []
    assert_equal 1, session.expect("tail", timeout: 0).number
  end

  def test_backpressure_reads_still_apply_escape_sequences
    source, = pipe_session
    reader, writer = IO.pipe
    sink, sink_writer = IO.pipe
    @ios.push(reader, writer, sink, sink_writer)
    loop { break if sink_writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    target = Expect.open(reader, writer: sink_writer, write_timeout: 1)
    @sessions << target
    output = StringIO.new
    received = Queue.new
    target.log_to { received << true }
    target.listeners = [output]
    target.on_sequence("STOP")
    source.listeners = [target]
    source.buffer = "request"
    writer.write("beforeSTOPtail")
    background do
      received.pop
      sink.readpartial(65_536)
    end

    assert_same(target, bounded { Expect.interconnect(target, source, timeout: 0.2) })
    assert_equal "before", output.string
    assert_equal "tail", target.buffer
    target.log_output = nil
    writer.write("ready")
    assert_equal 1, target.expect("ready", timeout: 1).number
    assert_equal "tail", target.before
  end

  def test_interconnect_forwards_and_strips_split_escape
    session, writer = pipe_session
    listener = StringIO.new
    session.listeners = [listener]
    session.on_sequence("STOP")
    background do
      writer.write("helloST")
      sleep 0.03
      writer.write("OPtail")
    end
    assert_same(session, bounded { Expect.interconnect(session) })
    assert_equal "hello", listener.string
    assert_equal "tail", session.buffer
  end

  def test_sequence_callback_parameters_and_resume
    session, writer = pipe_session
    listener = StringIO.new
    values = []
    session.listeners = [listener]
    session.on_sequence("!") do
      values << :event
      true
    end
    session.on_sequence("?")
    writer.write("one!two?three")
    Expect.interconnect(session, timeout: 1)
    assert_equal "onetwo", listener.string
    assert_equal [:event], values
    assert_equal "three", session.buffer
  end

  def test_zero_is_truthy_and_uppercase_eof_is_a_literal_sequence
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence("!") { 0 }
    session.on_sequence("EOF")
    writer.write("one!twoEOFtail")
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "onetwo", output.string
    assert_equal "tail", session.buffer
  end

  def test_eof_flushes_partial_escape
    session, writer = pipe_session
    listener = StringIO.new
    session.listeners = [listener]
    session.on_sequence("STOP")
    writer.write("helloST")
    writer.close
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "helloST", listener.string
  end

  def test_eof_handler_can_continue_other_sessions
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    listener = StringIO.new
    second.listeners = [listener]
    seen = []
    first.on_sequence(:eof) do
      seen << :first
      true
    end
    second.on_sequence("!")
    first_writer.close
    second_writer.write("second!")
    assert_same second, Expect.interconnect(first, second, timeout: 1)
    assert_equal [:first], seen
    assert_equal "second", listener.string
  end

  def test_interact_roundtrip_escape_and_restored_settings
    session = child(<<~'RUBY', raw_pty: true)
      while (value = STDIN.gets)
        puts "reply:#{value.strip}"
      end
    RUBY
    source, writer = pipe_session
    sink = StringIO.new
    listener = StringIO.new
    session.listeners = [listener]
    session.log_listeners = false
    source.on_sequence("original")
    background do
      writer.write("hello\n")
      # 收到真实响应后才发送退出键，避免将子进程启动速度当成交互完成条件。
      bounded { sleep 0.001 until sink.string == "reply:hello\n" }
      writer.write("\x1dtail")
    end
    assert_same(source, bounded { session.interact(input: source, escape: "\x1d", output: sink, timeout: 2) })
    assert_equal "reply:hello\n", sink.string
    assert_equal "tail", source.buffer
    assert_equal [listener], session.listeners
    refute session.log_listeners?
    assert_equal ["original"], source.__send__(:session).instance_variable_get(:@sequences).keys
  end

  def test_interconnect_leaves_terminal_modes_to_the_caller
    session = child('print "!"; sleep 30')
    original = terminal_configuration(session)
    seen = nil
    session.on_sequence("!") do
      seen = terminal_configuration(session)
      raise "stop"
    end
    assert_raises(RuntimeError) { Expect.interconnect(session, timeout: 1) }
    assert_equal original, seen
    assert_equal original, terminal_configuration(session)
  end

  def test_manual_stty_leaves_terminal_mode_to_caller
    session = child('print "!"; sleep 30')
    session.raw_terminal = false
    original = session.stty
    seen = nil
    session.on_sequence("!") do
      seen = session.stty
      false
    end
    Expect.interconnect(session, timeout: 1)
    assert_equal original, seen
  end

  def test_timeout_flushes_pending_escape_prefix
    session, writer = pipe_session
    listener = StringIO.new
    session.listeners = [listener]
    session.on_sequence("STOP")
    writer.write("helloST")
    assert_nil Expect.interconnect(session, timeout: 0.02)
    assert_equal "helloST", listener.string
    assert_empty session.buffer
  end

  def test_timeout_keeps_flushed_literal_prefix_in_regexp_history
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence("STOPS")
    session.on_sequence(/STOP/)
    writer.write("ST")

    assert_nil Expect.interconnect(session, timeout: 0)
    assert_equal "ST", output.string
    writer.write("OPtail")

    assert_same session, Expect.interconnect(session, timeout: 0.05)
    assert_equal "ST", output.string
    assert_equal "tail", session.buffer
  end

  def test_interconnect_retries_an_interrupted_select
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence("!")
    writer.write("ready!")
    original = IO.method(:select)
    interrupted = true
    select = lambda do |*arguments|
      if interrupted
        interrupted = false
        raise Errno::EINTR
      end
      original.call(*arguments)
    end

    IO.stub(:select, select) do
      assert_same session, Expect.interconnect(session, timeout: 1)
    end
    assert_equal "ready", output.string
  end

  def test_interconnect_retries_an_interrupted_read
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence("!")
    writer.write("ready!")
    original = session.to_io.method(:read_nonblock)
    interrupted = true
    read = lambda do |*arguments, **options|
      if interrupted
        interrupted = false
        raise Errno::EINTR
      end
      original.call(*arguments, **options)
    end

    session.to_io.stub(:read_nonblock, read) do
      assert_same session, Expect.interconnect(session, timeout: 1)
    end
    assert_equal "ready", output.string
  end

  def test_regexp_escape_matches_and_preserves_trailing_input
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence(/STOP\d+;/)
    writer.write("beforeSTOP42;after")
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "before", output.string
    assert_equal "after", session.buffer
  end

  def test_regexp_escape_tracks_prior_reads_without_delaying_forwarding
    session, writer = pipe_session
    seen = []
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence(/STOP\d+;/) do
      seen << :stopped
      false
    end
    # Await actual forwarding before writing the continuation, ensuring the
    # test cannot accidentally pass with a single combined read.
    background do
      writer.write("beforeSTOP")
      bounded { sleep 0.001 until output.string == "beforeSTOP" }
      writer.write("42;after")
    end
    assert_same(session, bounded { Expect.interconnect(session, timeout: 1) })
    assert_equal [:stopped], seen
    assert_equal "beforeSTOP", output.string
    assert_equal "after", session.buffer
  end

  def test_regexp_escape_history_has_a_finite_default_window
    session, = pipe_session
    session.on_sequence(/UNLIKELY_ESCAPE/)
    buffers = { session => "".b }

    5.times do
      buffers[session] << ("x" * 16_384)
      Expect::Interaction.relay_buffer(session.__send__(:session),
                                       { session.__send__(:session) => buffers.fetch(session) })
    end

    assert_operator session.__send__(:session).__send__(:relay_history).bytesize, :<=, 65_536
    assert_empty buffers.fetch(session)
  end

  def test_utf8_regexp_escape_history_keeps_a_valid_leading_character
    session, = pipe_session
    session.on_sequence(/终止/u)
    buffers = { session => "".b }

    6.times do
      buffers[session] << ("中" * 5461).b
      assert Expect::Interaction.relay_buffer(session.__send__(:session),
                                              { session.__send__(:session) => buffers.fetch(session) })
    end

    assert_operator session.__send__(:session).__send__(:relay_history).bytesize, :<=, 65_536
    assert session.__send__(:session).__send__(:relay_history).dup.force_encoding(Encoding::UTF_8).valid_encoding?
    buffers[session] << "终止".b
    refute Expect::Interaction.relay_buffer(session.__send__(:session),
                                            { session.__send__(:session) => buffers.fetch(session) })
  end

  def test_regexp_escape_continuation_does_not_rematch_history
    session, writer = pipe_session
    seen = []
    output = StringIO.new
    session.listeners = [output]
    session.on_sequence(/\[[0-9]+\]/) do
      seen << :hit
      true
    end
    session.on_sequence("!")
    writer.write("one[12]two[34]three!tail")
    Expect.interconnect(session, timeout: 1)
    assert_equal %i[hit hit], seen
    assert_equal "onetwothree", output.string
    assert_equal "tail", session.buffer
  end

  def test_zero_width_regexp_escape_is_rejected_without_spinning
    session, writer = pipe_session
    session.on_sequence(/(?=a)/) { true }
    writer.write("abc")
    assert_raises(ArgumentError) { bounded { Expect.interconnect(session, timeout: 1) } }
    assert_equal "abc", session.buffer
  end

  def test_log_failure_preserves_received_bytes_for_recovery
    session, writer = pipe_session
    session.log_to { raise IOError, "log failed" }
    writer.write("before!tail")

    error = assert_raises(IOError) { Expect.interconnect(session, timeout: 1) }
    assert_equal "log failed", error.message
    assert_equal "before!tail", session.buffer
    refute session.eof?

    session.log_output = nil
    assert_equal 1, session.expect("before!", timeout: 0).number
    assert_equal "tail", session.buffer
  end

  def test_logs_received_bytes_once_across_expect_interconnect_and_expect
    session, writer = pipe_session
    log = StringIO.new
    output = StringIO.new
    session.log_to(log)
    session.listeners = [output]
    session.on_sequence("!")
    writer.write("prompt>before!")
    session.expect("prompt>", timeout: 1)
    Expect.interconnect(session, timeout: 1)
    writer.write("after")
    session.expect("after", timeout: 1)
    assert_equal "prompt>before!after", log.string
  end

  def test_log_includes_escape_and_tail_before_next_expect
    session, writer = pipe_session
    log = StringIO.new
    output = StringIO.new
    session.log_to(log)
    session.listeners = [output]
    session.on_sequence("!")
    writer.write("before!tail")
    Expect.interconnect(session, timeout: 1)
    assert_equal "before", output.string
    assert_equal "before!tail", log.string
    assert_equal 1, session.expect("tail", timeout: 0).number
    assert_equal "before!tail", log.string
  end
end
