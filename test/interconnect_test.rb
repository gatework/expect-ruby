# frozen_string_literal: true

require_relative "test_helper"

class InterconnectTest < ExpectTest
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
      sleep 0.12
      writer.write("\x1dtail")
    end
    assert_same(source, bounded { session.interact(input: source, escape: "\x1d", output: sink, timeout: 2) })
    assert_equal "reply:hello\n", sink.string
    assert_equal "tail", source.buffer
    assert_equal [listener], session.listeners
    refute session.log_listeners
    assert_equal ["original"], source.instance_variable_get(:@sequences).keys
  end

  def test_terminal_modes_restore_after_callback_exception
    session = child('print "!"; sleep 30')
    mode = session.to_io.console_mode
    original = terminal_configuration(session)
    session.on_sequence("!") { raise "stop" }
    assert_raises(RuntimeError) { Expect.interconnect(session, timeout: 1) }
    assert_equal original, terminal_configuration(session)
    refute_nil mode
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
    assert_equal 1, session.expect("tail", timeout: 0)
    assert_equal "before!tail", log.string
  end
end
