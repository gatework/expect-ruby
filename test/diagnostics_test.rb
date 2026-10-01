# frozen_string_literal: true

require_relative "test_helper"
require "logger"

class DiagnosticsTest < ExpectTest
  def test_logger_receives_lifecycle_and_payload_at_separate_levels
    session, writer = pipe_session
    output = StringIO.new
    logger = Logger.new(output)
    logger.level = Logger::INFO
    session.logger = logger
    writer.write("ready")
    session.expect("ready", timeout: 1)
    assert_includes output.string, "matched pattern 1"
    refute_includes output.string, "received"
    logger.level = Logger::DEBUG
    writer.write("next")
    session.expect("next", timeout: 1)
    assert_includes output.string, "received"
    assert_includes output.string, "next"
    session.close
    refute output.closed?
  end

  def test_constructor_borrows_logger_and_transcript_as_separate_streams
    diagnostics = StringIO.new
    transcript = StringIO.new
    session, writer = pipe_session(logger: Logger.new(diagnostics), transcript:)
    writer.write("ready")
    session.expect("ready", timeout: 1)
    assert_equal "ready", transcript.string
    assert_includes diagnostics.string, "received"
    session.close
    refute diagnostics.closed?
    refute transcript.closed?
  end

  def test_logger_formatter_receives_immutable_metadata_without_the_session
    events = []
    session, writer = pipe_session(logger: recording_logger(events))
    writer.write("ready")
    session.expect("ready", timeout: 1)
    event = events.find { |item| item[:event] == :received }
    assert event.frozen?
    assert event[:message].frozen?
    refute_includes event.keys, :level
    assert_equal session.fileno, event[:fd]
    assert_equal 'received "ready"', event[:message]
    refute_includes event.values, session
    assert_equal :matched, events.last[:event]
  end

  def test_invalid_logger_preserves_the_previous_target
    session, = pipe_session
    output = StringIO.new
    logger = Logger.new(output)
    session.logger = logger
    [Object.new, StringIO.new, ->(_) {}].each do |invalid|
      assert_raises(ArgumentError) { session.logger = invalid }
      assert_same logger, session.logger
    end
  end

  def test_diagnostic_failure_keeps_original_input_available
    session, writer = pipe_session
    failure = IOError.new("diagnostic failed")
    session.logger = recording_logger([]) { raise failure }
    writer.write("ready")
    result = session.expect("ready", timeout: 1)
    assert_same failure, result.error
    assert_equal "ready", session.buffer
    session.logger = nil
    assert_equal 1, session.expect("ready", timeout: 0).number
  end

  def test_nested_diagnostic_wait_preserves_the_outer_match_result
    session, = pipe_session
    session.buffer = "ready"
    nested = nil
    notified = false
    callback_result = nil
    session.logger = recording_logger([]) do |event|
      next unless event[:event] == :matched && !notified

      notified = true
      nested = session.expect("missing", timeout: 0)
    end
    result = session.expect(timeout: 0) do |patterns|
      patterns.on("ready") { |source| callback_result = source.last_result }
    end
    assert nested.timeout?
    assert result.matched?
    assert_equal "ready", result.match
    assert_same result, callback_result
    assert_same result, session.last_result
  end

  def test_redaction_handles_every_two_chunk_split_and_overlapping_secrets
    (0..11).each do |split|
      session, = pipe_session
      output = StringIO.new
      session.transcript = output
      session.redact("abc", "bcd", "secret")
      text = "xabcdsecret!"
      session.write_transcript(text.byteslice(0, split))
      session.write_transcript(text.byteslice(split..))
      session.transcript = nil
      assert_equal "x[FILTERED]!", output.string, "split #{split}"
    end
  end

  def test_byte_at_a_time_redaction_preserves_matching_and_outputs
    session, writer = pipe_session
    events = []
    log = StringIO.new
    forwarded = StringIO.new
    session.logger = recording_logger(events)
    session.transcript = log
    session.outputs = [forwarded]
    session.redact("password")
    "password!".each_char do |byte|
      writer.write(byte)
      session.__send__(:read_available)
      refute_includes log.string, "password"
    end
    assert_equal 1, session.expect("password!", timeout: 0).number
    writer.close
    assert session.expect(:eof, timeout: 1).eof?
    assert_equal "[FILTERED]!", log.string
    assert_equal "password!", forwarded.string
    received = events.select { |event| event[:event] == :received }.map { |event| event[:message] }.join
    assert_includes received, "[FILTERED]"
    refute_includes events.inspect, "password"
    buffers = events.select { |event| event[:event] == :buffer }
    assert_empty buffers
  end

  def test_sending_diagnostics_are_filtered_across_separate_writes
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    output = StringIO.new
    session = Expect.open(client, logger: Logger.new(output))
    @sessions << session
    session.redact("password")
    %w[pa ss wo rd].each { |part| session.write(part) }
    assert_equal "password", peer.read(8)
    session.close
    refute_includes output.string, "password"
    refute_includes output.string, '"pa"'
    assert_includes output.string, "[FILTERED]"
  end

  def test_registration_copies_secrets_is_additive_and_isolated_between_sessions
    first, = pipe_session
    second, = pipe_session
    first_log = StringIO.new
    second_log = StringIO.new
    first.transcript = first_log
    second.transcript = second_log
    secret = +"first"
    assert_same first, first.redact(secret)
    secret.replace("changed")
    first.write_transcript("fi")
    first.redact("second")
    first.write_transcript("rst second")
    second.write_transcript("first second")
    first.close
    assert_equal "[FILTERED] [FILTERED]", first_log.string
    assert_equal "first second", second_log.string
  end

  def test_binary_secrets_are_matched_before_diagnostic_escaping
    session, = pipe_session
    log = StringIO.new
    diagnostics = StringIO.new
    session.transcript = log
    session.logger = Logger.new(diagnostics)
    secret = "\xff\0\n".b
    session.redact(secret)
    session.write_transcript("before#{secret}after".b)
    session.__send__(:trace_data, :received, secret)
    session.close
    assert_equal "before[FILTERED]after", log.string
    refute_includes diagnostics.string, '\\xFF'
    assert_includes diagnostics.string, "[FILTERED]"
  end

  def test_eof_and_close_flush_benign_tails_but_hide_incomplete_secret_prefixes
    session, writer = pipe_session
    log = StringIO.new
    session.transcript = log
    session.redact("password")
    writer.write("hello pass")
    writer.close
    assert session.expect(:eof, timeout: 1).eof?
    assert_equal "hello [FILTERED]", log.string
    session.close
    assert_equal "hello [FILTERED]", log.string
  end

  def test_replacing_log_finishes_the_original_target_and_keeps_it_borrowed
    session, = pipe_session
    first = StringIO.new
    second = StringIO.new
    session.redact("secret")
    session.transcript = first
    session.write_transcript("hello")
    session.transcript = second
    session.write_transcript("secret!")
    session.close
    assert_equal "hello", first.string
    assert_equal "[FILTERED]!", second.string
    refute first.closed?
    refute second.closed?
  end

  def test_invalid_registration_does_not_partially_add_secrets
    session, = pipe_session
    output = StringIO.new
    session.transcript = output
    [[], [""], [nil], ["valid", 42]].each do |values|
      assert_raises(ArgumentError) { session.redact(*values) }
    end
    session.write_transcript("valid")
    assert_equal "valid", output.string
  end

  def test_flush_failure_does_not_prevent_handle_and_child_cleanup
    session = child('puts "ready"; sleep 60', raw: true)
    session.expect("ready", timeout: 2)
    session.redact("password")
    failure = IOError.new("flush failed")
    transcript = StringIO.new
    transcript.define_singleton_method(:write) { |_| raise failure }
    session.transcript = transcript
    session.write_transcript("hi") # 小于保留窗口，失败应发生在关闭时的尾部交付。
    assert_same failure, assert_raises(IOError) { session.close }
    assert session.closed?
    refute session.alive?
    refute transcript.closed?
    session.transcript = nil
  end

  def test_replacing_diagnostics_finishes_the_previous_stream
    session, = pipe_session
    session.redact("password")
    first = StringIO.new
    second = StringIO.new
    session.logger = Logger.new(first)
    session.__send__(:trace_data, :received, "pass")
    session.logger = Logger.new(second)
    session.__send__(:trace_data, :received, "password!")
    session.close
    assert_includes first.string, "[FILTERED]"
    refute_includes first.string, "pass"
    assert_includes second.string, "[FILTERED]"
    refute_includes second.string, "password"
    refute first.closed?
    refute second.closed?
  end

  def test_diagnostic_formatter_can_create_or_revisit_the_other_direction
    [nil, "seed"].each do |initial_send|
      client, peer = Socket.pair(:UNIX, :STREAM, 0)
      @ios.push(client, peer)
      session = Expect.open(client)
      @sessions << session
      session.redact("long-secret")
      events = []
      session.logger = recording_logger(events) do |event|
        session.write("ack") if event[:event] == :received
      end
      if initial_send
        session.write(initial_send)
        assert_equal initial_send, peer.read(initial_send.bytesize)
      end
      peer.write("xyz")
      assert_equal 1, session.expect("xyz", timeout: 0).number
      replacement = StringIO.new
      session.logger = Logger.new(replacement)
      assert_equal "ack", peer.read(3)
      expected = initial_send ? %i[matched sending received sending] : %i[matched received sending]
      assert_equal(expected, events.map { |event| event[:event] })
      assert_includes events.last[:message], "ack"
      assert_equal "", replacement.string
      session.close
      assert_equal "", replacement.string
    end
  end

  def test_injected_logger_keeps_its_own_write_failure_policy
    output = StringIO.new
    session, writer = pipe_session(logger: Logger.new(output))
    writer.write("ready")
    _stdout, stderr = capture_io do
      output.stub(:write, ->(_) { raise IOError, "logger controlled failure" }) do
        assert_equal 1, session.expect("ready", timeout: 1).number
      end
    end
    assert_includes stderr, "logger controlled failure"

    failure = IOError.new("strict logger failure")
    session.logger = Logger.new(output, reraise_write_errors: [StandardError])
    writer.write("retained")
    output.stub(:write, ->(_) { raise failure }) do
      assert_same failure, session.expect("retained", timeout: 1).error
      assert_equal "retained", session.buffer
    end
  end

  def test_invalid_transcript_preserves_pending_data_and_previous_target
    transcript = StringIO.new
    session, = pipe_session(transcript:)
    session.redact("password")
    session.write_transcript("hello")
    [Object.new, "a-path.log", ->(_) {}].each do |invalid|
      assert_raises(ArgumentError) { session.transcript = invalid }
      assert_same transcript, session.transcript
      assert_empty transcript.string
    end
    session.close
    assert_equal "hello", transcript.string
  end

  def test_failed_transcript_flush_preserves_the_previous_target
    previous = StringIO.new
    replacement = StringIO.new
    session, = pipe_session(transcript: previous)
    session.redact("password")
    failure = IOError.new("old transcript failed")
    session.write_transcript("tail")
    previous.stub(:write, ->(_) { raise failure }) do
      assert_same failure, assert_raises(IOError) { session.transcript = replacement }
      assert_same previous, session.transcript
      assert_empty replacement.string
    end
    session.transcript = nil
    assert_nil session.transcript
  end

  def test_diagnostic_flush_failure_still_flushes_the_borrowed_transcript
    transcript = StringIO.new
    session, = pipe_session(transcript:)
    session.redact("password")
    failure = RuntimeError.new("diagnostic formatter failed")
    session.logger = recording_logger([]) { raise failure }
    session.write_transcript("tail")
    session.__send__(:trace_data, :sending, "hi")
    assert_same failure, assert_raises(RuntimeError) { session.close }
    assert_equal "tail", transcript.string
    refute transcript.closed?
    assert session.closed?
  end

  def test_transcript_writer_can_rotate_the_target_during_close
    session, = pipe_session
    session.redact("long-secret")
    first = StringIO.new
    second = StringIO.new
    write = first.method(:write)
    first.define_singleton_method(:write) do |data|
      count = write.call(data)
      session.transcript = second
      session.write_transcript("body")
      count
    end
    session.transcript = first
    session.write_transcript("xyz")
    session.close
    assert_equal "xyz", first.string
    assert_equal "body", second.string
    refute first.closed?
    refute second.closed?
    assert_nil session.transcript
  end

  private

  def recording_logger(events, &observe)
    diagnostic_logger do |event|
      events << event
      observe&.call(event)
    end
  end
end
