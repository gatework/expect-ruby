# frozen_string_literal: true

require_relative "test_helper"

class IOTest < ExpectTest
  def test_socket_pair_send_and_expect
    client, server = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, server)
    session = Expect.open(client)
    @sessions << session
    background do
      server.write("prompt>")
      server.write(server.gets.upcase)
    end
    assert_equal 1, session.expect("prompt>", timeout: 1)
    assert_equal 6, session.write("hello\n")
    assert_equal 1, session.expect("HELLO\n", timeout: 1)
  end

  def test_log_file_append_truncate_disable_and_manual_output
    session, writer = pipe_session
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.log")
      File.write(path, "old")
      log = session.log_to(path)
      writer.write("reply")
      session.expect("reply", timeout: 1)
      session.write_log(" annotation")
      session.log_output = nil
      assert log.closed?
      assert_equal "oldreply annotation", File.binread(path)
      session.log_to(path, mode: "w")
      writer.write("new")
      session.expect("new", timeout: 1)
      session.log_output = nil
      assert_equal "new", File.binread(path)
      writer.write("unlogged")
      session.expect("unlogged", timeout: 1)
      assert_equal "new", File.binread(path)
    end
  end

  def test_logging_matches_upstream_received_data_only
    session = child("puts STDIN.gets.reverse", raw_pty: true)
    chunks = []
    session.log_to(->(data) { chunks << data })
    session.write("abc\n")
    session.expect("cba", timeout: 2)
    assert_equal "\ncba\n", chunks.join
  end

  def test_group_and_stdout_logging_can_be_controlled_separately
    session, writer = pipe_session
    listener = StringIO.new
    session.listeners = [listener]
    writer.write("one")
    session.expect("one", timeout: 1)
    assert_equal "one", listener.string
    session.log_listeners = false
    session.log_stdout = true
    output, = capture_io do
      writer.write("two")
      session.expect("two", timeout: 1)
    end
    assert_equal "two", output
    assert_equal "one", listener.string
    session.listeners = []
    assert_empty session.listeners
  end

  def test_debug_and_internal_output
    session, writer = pipe_session
    session.debug_level = 1
    _, diagnostics = capture_io do
      writer.write("ready")
      session.expect("ready", timeout: 1)
    end
    assert_match(/matched pattern 1/, diagnostics)
    refute_match(/received/, diagnostics)
    session.debug_level = 2
    _, diagnostics = capture_io do
      writer.write("more")
      session.expect("more", timeout: 1)
    end
    assert_match(/received "more"/, diagnostics)
  end

  def test_send_slow_collects_replies_even_when_logging_disabled
    session = child("loop { char = STDIN.read(1); break unless char; print char.upcase }", raw_pty: true)
    session.log_listeners = false
    start = Expect.monotonic
    assert_equal 3, session.send_slow("abc", delay: 0.02)
    assert_operator Expect.monotonic - start, :>=, 0.06
    assert_equal 1, session.expect("ABC", timeout: 1)
  end

  def test_large_bidirectional_write_does_not_deadlock
    session = child("STDIN.binmode; STDOUT.binmode; loop { print STDIN.readpartial(4096) }", raw_pty: true,
                                                                                             write_timeout: 3)
    payload = (0..255).to_a.pack("C*") * 1024
    bounded do
      assert_equal payload.bytesize, session.write(payload)
      assert_equal 1, session.expect(payload, timeout: 3)
    end
    assert_equal payload, session.match
  end

  def test_write_timeout_on_backpressure
    session = child('puts "ready"; sleep 30', raw_pty: true, write_timeout: 0.05)
    session.expect("ready", timeout: 2)
    assert_raises(Expect::WriteTimeout) { bounded { session.write("x" * 1_000_000) } }
  end

  def test_readiness_returns_readable_sessions
    first, = pipe_session
    second, writer = pipe_session
    assert_empty Expect.readable_sessions(first, second)
    writer.write("data")
    assert_equal [second], Expect.readable_sessions(first, second)
    second.expect("data", timeout: 1)
    assert_empty Expect.readable_sessions(first, second)
  end

  def test_readiness_waits_for_data_and_does_not_consume_data
    first, = pipe_session
    second, writer = pipe_session
    background do
      sleep 0.03
      writer.write("ready")
    end
    assert_equal([second], bounded { Expect.readable_sessions(first, second, timeout: 1) })
    assert_equal 1, second.expect("ready", timeout: 0)
    assert_empty Expect.readable_sessions(first, second, timeout: 0)
  end

  def test_readiness_accepts_keyword_and_unlimited_timeout
    session, writer = pipe_session
    assert_empty Expect.readable_sessions(session, timeout: 0.01)
    background do
      sleep 0.03
      writer.write("ready")
    end
    assert_equal([session], bounded { Expect.readable_sessions(session, timeout: nil) })
    assert_equal [session], Expect.readable_sessions(session, timeout: 0)
    assert_raises(ArgumentError) { Expect.readable_sessions(session, timeout: -1) }
    assert_raises(ArgumentError) { Expect.readable_sessions(0, session, timeout: 1) }
    assert_raises(ArgumentError) { Expect.readable_sessions("invalid") }
  end

  def test_readiness_excludes_closed_sessions
    first, = pipe_session
    second, writer = pipe_session
    first.close
    writer.write("ready")
    assert_equal [second], Expect.readable_sessions(first, second, timeout: 0)
    assert_empty Expect.readable_sessions
  end

  def test_read_io_error_is_reported
    Tempfile.create("expect-write-only") do |file|
      File.open(file.path, "w") do |writer|
        session = Expect.open(writer)
        @sessions << session
        result = session.expect_result("x", timeout: 1)
        assert_instance_of IOError, result.error
      end
    end
  end

  def test_log_io_failure_does_not_masquerade_as_child_eof
    session = child('puts "ready"; STDIN.gets; puts "response"; sleep 30', raw_pty: true)
    assert_equal 1, session.expect("ready\n", timeout: 2)
    session.log_to(->(_) { raise Errno::EIO, "log failed" })
    session.write("continue\n")
    result = session.expect_result("response", timeout: 2)
    assert_instance_of Errno::EIO, result.error
    refute result.eof?
    refute session.eof?
    assert session.alive?
    assert_includes result.before, "response\n"
    session.log_output = nil
    assert_equal 1, session.expect("response", timeout: 0)
  end
end
