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
    assert_equal 1, session.expect("prompt>", timeout: 1).number
    assert_equal 6, session.write("hello\n")
    assert_equal 1, session.expect("HELLO\n", timeout: 1).number
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

  def test_new_log_files_are_private_without_changing_existing_permissions
    session, = pipe_session
    Dir.mktmpdir do |directory|
      previous_umask = File.umask(0o022)
      begin
        %w[a w].each do |mode|
          path = File.join(directory, "session-#{mode}.log")
          session.log_to(path, mode:)
          assert_equal 0o600, File.stat(path).mode & 0o777
          session.log_output = nil
          File.chmod(0o640, path)
          session.log_to(path, mode:)
          assert_equal 0o640, File.stat(path).mode & 0o777
        end
      ensure
        File.umask(previous_umask)
      end
    end
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
      session.expect("two", timeout: 1).number
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
      session.expect("ready", timeout: 1).number
    end
    assert_match(/matched pattern 1/, diagnostics)
    refute_match(/received/, diagnostics)
    session.debug_level = 2
    _, diagnostics = capture_io do
      writer.write("more")
      session.expect("more", timeout: 1).number
    end
    assert_match(/received "more"/, diagnostics)
  end

  def test_quiet_mode_does_not_format_byte_content_for_diagnostics
    session, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(session, peer)
    connection = Expect.open(session, debug_level: 0)
    @sessions << connection
    inspected = 0
    probe = TracePoint.new(:c_call) do |event|
      inspected += 1 if event.defined_class == String && event.method_id == :inspect
    end

    probe.enable do
      connection.write("hello")
      peer.write("reply")
      connection.expect("reply", timeout: 1).number
    end

    assert_equal 0, inspected
  end

  def test_send_slow_collects_replies_even_when_logging_disabled
    session = child("loop { char = STDIN.read(1); break unless char; print char.upcase }", raw_pty: true)
    session.log_listeners = false
    start = Expect.monotonic
    assert_equal 3, session.send_slow("abc", delay: 0.02)
    assert_operator Expect.monotonic - start, :>=, 0.06
    assert_equal 1, session.expect("ABC", timeout: 1).number
  end

  def test_send_slow_zero_delay_only_polls_and_later_reply_remains_readable
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    session = Expect.open(client, log_stdout: false)
    @sessions << session
    waits = []
    original = client.method(:wait_readable)
    client.stub(:wait_readable, lambda { |timeout|
      waits << timeout
      original.call(0)
    }) do
      assert_equal 8, session.send_slow("a中😀", delay: 0)
    end
    assert_equal [0, 0, 0], waits
    assert_equal("a中😀".b, bounded { peer.read(8) })
    peer.write("late reply")
    assert_equal 1, session.expect("late reply", timeout: 1).number
    assert_empty session.buffer
  end

  def test_send_slow_preserves_character_delay_and_write_timeout
    session, = pipe_session
    calls = []
    failure = Expect::WriteTimeout.new(bytes_written: 0)
    session.__send__(:session).stub(:sleep, ->(duration) { calls << [:sleep, duration] }) do
      session.__send__(:session).stub(:write, lambda { |data|
        calls << [:write, data]
        raise failure
      }) do
        assert_same failure, assert_raises(Expect::WriteTimeout) { session.send_slow("中b", delay: 0.25) }
      end
    end
    assert_equal [[:sleep, 0.25], [:write, "中"]], calls
  end

  def test_large_bidirectional_write_does_not_deadlock
    session = child("STDIN.binmode; STDOUT.binmode; loop { print STDIN.readpartial(4096) }", raw_pty: true,
                                                                                             write_timeout: 3)
    payload = (0..255).to_a.pack("C*") * 1024
    bounded do
      assert_equal payload.bytesize, session.write(payload)
      assert_equal 1, session.expect(payload, timeout: 3).number
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

  def test_readiness_keeps_distinct_sessions_with_equal_values
    type = Class.new(Expect) do
      def ==(other) = other.is_a?(self.class)
      alias eql? ==
      def hash = 0
    end
    sources = Array.new(2) do
      reader, writer = IO.pipe
      @ios.push(reader, writer)
      session = type.open(reader)
      @sessions << session
      [session, writer]
    end
    first, second = sources.map(&:first)
    sources.last.last.write("ready")

    ready = Expect.readable_sessions(first, second, second)
    assert_equal 1, ready.size
    assert_same second, ready.first
    assert_equal "ready", second.to_io.read_nonblock(5)
  end

  def test_readiness_uses_io_identity_when_selecting_ready_sessions
    first, = pipe_session
    second, writer = pipe_session
    second.to_io.define_singleton_method(:==) { |_other| true }
    writer.write("ready")

    ready = Expect.readable_sessions(first, second)
    assert_equal 1, ready.size
    assert_same second, ready.first
    assert_equal "ready", second.to_io.read_nonblock(5)
  end

  def test_readiness_retries_an_interrupted_select
    session, writer = pipe_session
    writer.write("ready")
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
      assert_equal [session], Expect.readable_sessions(session, timeout: 1)
    end
  end

  def test_write_retries_an_interrupted_nonblocking_write
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(reader, writer)
    session = Expect.open(reader)
    @sessions << session
    original = reader.method(:write_nonblock)
    interrupted = true
    write = lambda do |*arguments, **options|
      if interrupted
        interrupted = false
        raise Errno::EINTR
      end
      original.call(*arguments, **options)
    end

    reader.stub(:write_nonblock, write) do
      assert_equal 5, session.write("hello")
    end
    assert_equal "hello", writer.read(5)
  end

  def test_write_retries_an_interrupted_writable_wait
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(reader, writer)
    session = Expect.open(reader, write_timeout: 1)
    @sessions << session
    original = reader.method(:write_nonblock)
    waiting = true
    write = lambda do |*arguments, **options|
      if waiting
        waiting = false
        :wait_writable
      else
        original.call(*arguments, **options)
      end
    end

    reader.stub(:write_nonblock, write) do
      IO.stub(:select, ->(*) { raise Errno::EINTR }) do
        assert_equal 5, session.write("hello")
      end
    end
    assert_equal "hello", writer.read(5)
  end

  def test_readiness_waits_for_data_and_does_not_consume_data
    first, = pipe_session
    second, writer = pipe_session
    background do
      sleep 0.03
      writer.write("ready")
    end
    assert_equal([second], bounded { Expect.readable_sessions(first, second, timeout: 1) })
    assert_equal 1, second.expect("ready", timeout: 0).number
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
        result = session.expect("x", timeout: 1)
        assert_instance_of IOError, result.error
      end
    end
  end

  def test_log_io_failure_does_not_masquerade_as_child_eof
    session = child('puts "ready"; STDIN.gets; puts "response"; sleep 30', raw_pty: true)
    assert_equal 1, session.expect("ready\n", timeout: 2).number
    session.log_to(->(_) { raise Errno::EIO, "log failed" })
    session.write("continue\n")
    result = session.expect("response", timeout: 2)
    assert_instance_of Errno::EIO, result.error
    refute result.eof?
    refute session.eof?
    assert session.alive?
    assert_includes result.before, "response\n"
    session.log_output = nil
    assert_equal 1, session.expect("response", timeout: 0).number
  end
end
