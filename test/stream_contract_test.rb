# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class StreamContractTest < ExpectTest
  def test_shared_reader_is_read_once_before_matching_a_bounded_window
    Tempfile.create("expect-shared-reader") do |io|
      io.binmode
      io.write("READY#{"x" * ((Expect::READ_SIZE * 2) - 5)}")
      io.rewind
      sources = Array.new(2) { Expect.open(io, buffer_limit: Expect::READ_SIZE) }
      @sessions.concat(sources)

      result = Expect.expect("READY", from: sources, timeout: 0)

      assert result.matched?
      assert_same sources.first, result.session
      assert_equal Expect::READ_SIZE, io.pos
      assert_equal 0, sources.first.buffer_discarded_bytes
      assert_empty sources.last.buffer
    end
  end

  def test_level_changes_preserve_redaction_without_releasing_disabled_bytes
    %i[received sending].each do |direction|
      client, peer = Socket.pair(:UNIX, :STREAM, 0)
      @ios.push(client, peer)
      events = []
      logger = diagnostic_logger { |event| events << event }
      session = Expect.open(client, logger:)
      @sessions << session
      session.redact("synthetic-password")
      [[Logger::DEBUG, "synthetic-"], [Logger::INFO, "pass"], [Logger::DEBUG, "word!"]].each do |level, bytes|
        logger.level = level
        if direction == :received
          peer.write(bytes)
          assert session.expect(bytes, timeout: 1).matched?
        else
          session.write(bytes)
          assert_equal bytes, peer.read(bytes.bytesize)
        end
      end
      session.close
      messages = events.select { |event| event[:event] == direction }.map { |event| event[:message] }.join
      assert_includes messages, "!"
      refute_includes messages, "synthetic"
      refute_includes messages, "word"
    end
  end

  def test_enabling_debug_does_not_release_a_previously_suppressed_tail
    session, writer = pipe_session
    events = []
    logger = diagnostic_logger(level: Logger::INFO) { |event| events << event }
    session.logger = logger
    session.redact("long-secret")
    writer.write("private")
    assert session.expect("private", timeout: 1).matched?
    logger.level = Logger::DEBUG
    writer.write("visible")
    assert session.expect("visible", timeout: 1).matched?
    session.close

    messages = events.select { |event| event[:event] == :received }.map { |event| event[:message] }.join
    refute_includes messages, "private"
    assert_includes messages, "visible"
  end

  def test_relay_and_direct_writes_share_continuous_sending_redaction
    source, = pipe_session
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    events = []
    target = Expect.open(client, logger: diagnostic_logger { |event| events << event })
    @sessions << target
    target.redact("synthetic-password")
    target.write("synthetic-")
    source.outputs = [target]
    source.buffer = "pass"
    Expect.interconnect(source, timeout: 0)
    target.write("word!")
    assert_equal "synthetic-password!", peer.read(19)
    target.close

    messages = events.select { |event| event[:event] == :sending }.map { |event| event[:message] }.join
    assert_includes messages, "[FILTERED]"
    refute_includes messages, "synthetic"
    refute_includes messages, "word"
  end

  def test_relay_diagnostic_failure_keeps_accepted_progress_for_retry
    source, = pipe_session
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    events = []
    failure = IOError.new("diagnostic failed after delivery")
    target = Expect.open(client, logger: diagnostic_logger do |event|
      events << event
      raise failure if event[:event] == :sending && events.size == 1
    end)
    @sessions << target
    source.outputs = [target]
    source.buffer = "once"

    assert_same failure, assert_raises(IOError) { Expect.interconnect(source, timeout: 0) }
    assert_equal "once", peer.read(4)
    Expect.interconnect(source, timeout: 0)
    refute source.pending_output?
    assert_equal :wait_readable, peer.read_nonblock(4, exception: false)
    sending = events.count { |event| event[:event] == :sending }
    assert_equal 1, sending
  end

  def test_relay_reports_only_accepted_short_writes_and_resumes_after_diagnostic_timeout
    source, = pipe_session
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    events = []
    failure = Expect::WriteTimeout.new("nested write failed", bytes_written: 97)
    target = Expect.open(client, logger: diagnostic_logger do |event|
      next unless event[:event] == :sending

      events << event[:message]
      raise failure if events.size == 1
    end)
    @sessions << target
    source.outputs = [target]
    source.buffer = "abcdef"
    write = client.method(:write_nonblock)
    client.define_singleton_method(:write_nonblock) do |data, **options|
      write.call(data.byteslice(0, 2), **options)
    end

    error = assert_raises(Expect::WriteTimeout) { Expect.interconnect(source, timeout: 1) }
    assert_equal 2, error.bytes_written
    assert_same failure, error.cause
    assert_equal "ab", peer.read(2)
    assert source.pending_output?
    # 零预算只允许有限次尝试，连续恢复仍不能重放已确认的前缀。
    2.times { Expect.interconnect(source, timeout: 0) }
    assert_equal "cdef", peer.read(4)
    assert_equal ['sending "ab"', 'sending "cd"', 'sending "ef"'], events
    refute source.pending_output?
  end

  def test_relay_checks_deadline_between_continuing_escape_callbacks
    source, = pipe_session
    source.buffer = "XXXtail"
    now = 0.0
    calls = 0
    source.on_sequence("X") do
      calls += 1
      now += 1
      true
    end

    Expect.stub(:monotonic, -> { now }) do
      assert_nil Expect.interconnect(source, timeout: 0.5)
    end
    assert_equal 1, calls
    assert_equal "XXtail", source.buffer
  end

  def test_relay_checks_deadline_after_a_deferred_escape_callback
    source, = pipe_session
    output = StringIO.new
    source.outputs = [output]
    source.buffer = "prefixXtail"
    now = 0.0
    source.on_sequence("X") do
      now = 1.0
      true
    end

    Expect.stub(:monotonic, -> { now }) do
      assert_nil Expect.interconnect(source, timeout: 0.5)
    end
    assert_equal "prefix", output.string
    assert_equal "tail", source.buffer
  end

  def test_relay_checks_deadline_after_eof_continuation_before_another_source
    ended, writer = pipe_session
    writer.close
    assert ended.expect(:eof, timeout: 1).eof?
    active, = pipe_session
    active.buffer = "Xtail"
    now = 0.0
    ended.on_sequence(:eof) do
      now = 1.0
      true
    end
    active.on_sequence("X") { flunk "callback after the shared deadline" }

    Expect.stub(:monotonic, -> { now }) do
      assert_nil Expect.interconnect(ended, active, timeout: 0.5)
    end
    assert_equal "Xtail", active.buffer
  end

  def test_relay_preserves_input_when_literal_prefix_scanning_exhausts_the_budget
    source, = pipe_session
    output = StringIO.new
    source.outputs = [output]
    source.buffer = "tailX"
    source.on_sequence("XYZ")
    now = 0.0
    original = Expect::Interaction.method(:hold_literal_prefix)
    scan = lambda do |*arguments|
      result = original.call(*arguments)
      now = 1.0
      result
    end

    Expect.stub(:monotonic, -> { now }) do
      Expect::Interaction.stub(:hold_literal_prefix, scan) do
        assert_nil Expect.interconnect(source, timeout: 0.5)
      end
    end
    assert_empty output.string
    assert_equal "tailX", source.buffer
  end

  def test_explicit_escape_stop_takes_precedence_after_callback_crosses_deadline
    source, = pipe_session
    source.buffer = "Xtail"
    now = 0.0
    source.on_sequence("X") do
      now = 1.0
      false
    end

    Expect.stub(:monotonic, -> { now }) do
      assert_same source, Expect.interconnect(source, timeout: 0.5)
    end
    assert_equal "tail", source.buffer
  end

  def test_received_hooks_cannot_recursively_read_the_same_stream
    %i[logger transcript outputs].each do |channel|
      session, writer = pipe_session
      transcript = StringIO.new
      output = StringIO.new
      session.transcript = transcript
      session.outputs = [output]
      nested_errors = []
      attempted = false
      handler = lambda do
        next if attempted

        attempted = true
        writer.write("B")
        2.times do
          nested_errors << assert_raises(Expect::ReentrancyError) { session.expect("B", timeout: 0) }
        end
      end
      case channel
      when :logger
        session.logger = diagnostic_logger { |event| handler.call if event[:event] == :received }
      when :transcript, :outputs
        target = channel == :transcript ? transcript : output
        original = target.method(:write)
        target.define_singleton_method(:write) do |data|
          handler.call
          original.call(data)
        end
      end
      writer.write("A")
      assert session.expect("A", timeout: 0).matched?
      assert_equal 2, nested_errors.size
      assert session.expect("B", timeout: 0).matched?
      assert_equal "AB", transcript.string
      assert_equal "AB", output.string
    end
  end

  def test_received_hook_can_match_buffered_text_and_read_an_independent_source
    source, producer = pipe_session
    other, other_producer = pipe_session
    nested = []
    entered = false
    source.logger = diagnostic_logger do |event|
      next unless event[:event] == :received && !entered

      entered = true
      nested << source.expect("A", timeout: 0).match
      nested << other.expect("B", timeout: 0).match
    end
    transcript = StringIO.new
    source.transcript = transcript
    producer.write("AC")
    other_producer.write("B")

    assert_equal "C", source.expect("C", timeout: 0).match
    assert_equal %w[A B], nested
    assert_equal "AC", transcript.string
  end

  def test_received_hook_failure_releases_the_read_guard
    source, producer = pipe_session
    entered = false
    source.logger = diagnostic_logger do |event|
      next unless event[:event] == :received && !entered

      entered = true
      producer.write("B")
      source.expect("B", timeout: 0)
    end
    producer.write("A")

    assert_raises(Expect::ReentrancyError) { source.expect("missing", timeout: 0) }
    assert_equal "A", source.expect("A", timeout: 0).match
    assert_equal "B", source.expect("B", timeout: 0).match
  end
end
