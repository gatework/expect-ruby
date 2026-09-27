# frozen_string_literal: true

require_relative "test_helper"
require "logger"

class DiagnosticsTest < ExpectTest
  def test_logger_receives_lifecycle_and_payload_at_separate_levels
    session, writer = pipe_session(debug_level: 2)
    output = StringIO.new
    logger = Logger.new(output)
    logger.level = Logger::INFO
    session.diagnostic_output = logger
    writer.write("ready")
    session.expect("ready", timeout: 1)
    assert_includes output.string, "matched pattern 1"
    refute_includes output.string, "received"
    logger.level = Logger::DEBUG
    writer.write("next")
    session.expect("next", timeout: 1)
    assert_includes output.string, 'received "next"'
    session.close
    refute output.closed?
  end

  def test_constructor_accepts_borrowed_diagnostic_io_and_keeps_transcript_separate
    diagnostics = StringIO.new
    session, writer = pipe_session(debug_level: 2, diagnostic_output: diagnostics)
    transcript = StringIO.new
    session.log_to(transcript)
    writer.write("ready")
    session.expect("ready", timeout: 1)
    assert_equal "ready", transcript.string
    assert_includes diagnostics.string, 'received "ready"'
    session.close
    refute diagnostics.closed?
    refute transcript.closed?
  end

  def test_callable_diagnostics_receive_immutable_metadata_without_the_session
    events = []
    session, writer = pipe_session(debug_level: 2, diagnostic_output: ->(event) { events << event })
    writer.write("ready")
    session.expect("ready", timeout: 1)
    event = events.find { |item| item[:event] == :received }
    assert event.frozen?
    assert event[:message].frozen?
    assert_equal :debug, event[:level]
    assert_equal session.fileno, event[:fd]
    assert_equal 'received "ready"', event[:message]
    refute_includes event.values, session
    assert_equal :info, events.last[:level]
  end

  def test_invalid_diagnostic_target_preserves_the_previous_target
    session, = pipe_session
    output = StringIO.new
    session.diagnostic_output = output
    assert_raises(ArgumentError) { session.diagnostic_output = Object.new }
    assert_same output, session.diagnostic_output
  end

  def test_diagnostic_failure_keeps_original_input_available
    session, writer = pipe_session(debug_level: 2)
    failure = IOError.new("diagnostic failed")
    session.diagnostic_output = ->(_) { raise failure }
    writer.write("ready")
    result = session.expect_result("ready", timeout: 1)
    assert_same failure, result.error
    assert_equal "ready", session.buffer
    session.debug_level = 0
    assert_equal 1, session.expect("ready", timeout: 0)
  end

  def test_nested_diagnostic_wait_preserves_the_outer_match_result
    session, = pipe_session(debug_level: 1)
    session.buffer = "ready"
    nested = nil
    notified = false
    callback_result = nil
    session.diagnostic_output = lambda do |event|
      next unless event[:event] == :matched && !notified

      notified = true
      nested = session.expect_result("missing", timeout: 0)
    end
    result = session.expect_result(timeout: 0) do |patterns|
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
      session.log_to(output)
      session.redact("abc", "bcd", "secret")
      text = "xabcdsecret!"
      session.write_log(text.byteslice(0, split))
      session.write_log(text.byteslice(split..))
      session.log_output = nil
      assert_equal "x[FILTERED]!", output.string, "split #{split}"
    end
  end

  def test_byte_at_a_time_redaction_preserves_matching_and_listeners
    session, writer = pipe_session(debug_level: 3)
    events = []
    log = StringIO.new
    forwarded = StringIO.new
    session.diagnostic_output = ->(event) { events << event }
    session.log_to(log)
    session.listeners = [forwarded]
    session.redact("password")
    "password!".each_char do |byte|
      writer.write(byte)
      session.__send__(:read_available)
      refute_includes log.string, "password"
    end
    assert_equal 1, session.expect("password!", timeout: 0)
    writer.close
    assert session.expect_result(:eof, timeout: 1).eof?
    assert_equal "[FILTERED]!", log.string
    assert_equal "password!", forwarded.string
    received = events.select { |event| event[:event] == :received }.map { |event| event[:message] }.join
    assert_includes received, "[FILTERED]"
    refute_includes events.inspect, "password"
    buffers = events.select { |event| event[:event] == :buffer }
    assert(buffers.all? { |event| event[:message] == "buffer [FILTERED]" })
  end

  def test_sending_diagnostics_are_filtered_across_separate_writes
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, peer)
    output = StringIO.new
    session = Expect.open(client, debug_level: 2, diagnostic_output: output)
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
    first.log_to(first_log)
    second.log_to(second_log)
    secret = +"first"
    assert_same first, first.redact(secret)
    secret.replace("changed")
    first.write_log("fi")
    first.redact("second")
    first.write_log("rst second")
    second.write_log("first second")
    first.close
    assert_equal "[FILTERED] [FILTERED]", first_log.string
    assert_equal "first second", second_log.string
  end

  def test_binary_secrets_are_matched_before_diagnostic_escaping
    session, = pipe_session(debug_level: 2)
    log = StringIO.new
    diagnostics = StringIO.new
    session.log_to(log)
    session.diagnostic_output = diagnostics
    secret = "\xff\0\n".b
    session.redact(secret)
    session.write_log("before#{secret}after".b)
    session.__send__(:trace_data, :received, secret, level: 2)
    session.close
    assert_equal "before[FILTERED]after", log.string
    refute_includes diagnostics.string, '\\xFF'
    assert_includes diagnostics.string, "[FILTERED]"
  end

  def test_eof_and_close_flush_benign_tails_but_hide_incomplete_secret_prefixes
    session, writer = pipe_session
    log = StringIO.new
    session.log_to(log)
    session.redact("password")
    writer.write("hello pass")
    writer.close
    assert session.expect_result(:eof, timeout: 1).eof?
    assert_equal "hello [FILTERED]", log.string
    session.close
    assert_equal "hello [FILTERED]", log.string
  end

  def test_replacing_log_finishes_the_original_target_and_keeps_it_borrowed
    session, = pipe_session
    first = StringIO.new
    second = StringIO.new
    session.redact("secret")
    session.log_to(first)
    session.write_log("hello")
    session.log_to(second)
    session.write_log("secret!")
    session.close
    assert_equal "hello", first.string
    assert_equal "[FILTERED]!", second.string
    refute first.closed?
    refute second.closed?
  end

  def test_invalid_registration_does_not_partially_add_secrets
    session, = pipe_session
    output = StringIO.new
    session.log_to(output)
    [[], [""], [nil], ["valid", 42]].each do |values|
      assert_raises(ArgumentError) { session.redact(*values) }
    end
    session.write_log("valid")
    assert_equal "valid", output.string
  end

  def test_reopening_the_same_log_path_finishes_the_old_stream_before_truncating
    session, = pipe_session
    session.redact("password")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      previous = session.log_to(path, mode: "w")
      session.write_log("hello")
      assert_equal "", File.binread(path)
      session.log_to(path, mode: "w")
      assert previous.closed?
      session.write_log("x")
      session.close
      assert_equal "x", File.binread(path)
    end
  end

  def test_failed_old_log_flush_does_not_truncate_the_new_path
    session, = pipe_session
    session.redact("password")
    failure = IOError.new("old log failed")
    session.log_to { raise failure }
    session.write_log("tail")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "existing.log")
      File.write(path, "keep")
      assert_same failure, assert_raises(IOError) { session.log_to(path, mode: "w") }
      assert_equal "keep", File.binread(path)
    end
    session.log_output = nil
    assert_nil session.log_output
  end

  def test_flush_failure_does_not_prevent_handle_and_child_cleanup
    session = child('puts "ready"; sleep 60', raw_pty: true)
    session.expect("ready", timeout: 2)
    session.redact("password")
    failure = IOError.new("flush failed")
    session.log_to { raise failure }
    session.write_log("hi") # 小于保留窗口，失败应发生在关闭时的尾部交付。
    assert_same failure, assert_raises(IOError) { session.close }
    assert session.closed?
    refute session.alive?
    session.log_output = nil
  end

  def test_unexpected_diagnostic_flush_failure_still_closes_owned_log
    session, = pipe_session(debug_level: 2)
    session.redact("password")
    Dir.mktmpdir do |directory|
      log = session.log_to(File.join(directory, "session.log"))
      failure = RuntimeError.new("diagnostic callback failed")
      session.diagnostic_output = ->(_) { raise failure }
      session.__send__(:trace_data, :sending, "hi", level: 2)
      assert_same failure, assert_raises(RuntimeError) { session.close }
      assert log.closed?
      assert session.closed?
    end
  end

  def test_replacing_diagnostics_finishes_the_previous_stream
    session, = pipe_session(debug_level: 2)
    session.redact("password")
    first = StringIO.new
    second = StringIO.new
    session.diagnostic_output = first
    session.__send__(:trace_data, :received, "pass", level: 2)
    session.diagnostic_output = second
    session.__send__(:trace_data, :received, "password!", level: 2)
    session.close
    assert_includes first.string, "[FILTERED]"
    refute_includes first.string, "pass"
    assert_includes second.string, "[FILTERED]"
    refute_includes second.string, "password"
    refute first.closed?
    refute second.closed?
  end

  def test_log_callback_can_rotate_the_target_during_close
    session, = pipe_session
    session.redact("long-secret")
    delivered = []
    rotated = nil
    Dir.mktmpdir do |directory|
      path = File.join(directory, "rotated.log")
      session.log_to do |data|
        delivered << data
        rotated = session.log_to(path, mode: "w")
        session.write_log("body")
      end
      session.write_log("xyz")
      session.close
      assert_equal ["xyz"], delivered
      assert rotated.closed?
      assert_equal "body", File.binread(path)
      assert_nil session.log_output
    end
  end

  def test_diagnostic_flush_callback_can_create_or_revisit_the_other_direction
    [nil, "seed"].each do |initial_send|
      client, peer = Socket.pair(:UNIX, :STREAM, 0)
      @ios.push(client, peer)
      session = Expect.open(client, debug_level: 2)
      @sessions << session
      session.redact("long-secret")
      events = []
      session.diagnostic_output = lambda do |event|
        events << event
        session.write("ack") if event[:event] == :received
      end
      if initial_send
        session.write(initial_send)
        assert_equal initial_send, peer.read(initial_send.bytesize)
      end
      peer.write("xyz")
      assert_equal 1, session.expect("xyz", timeout: 0)
      replacement = StringIO.new
      session.diagnostic_output = replacement
      assert_equal "ack", peer.read(3)
      expected = initial_send ? %i[matched sending received sending] : %i[matched received sending]
      assert_equal(expected, events.map { |event| event[:event] })
      assert_includes events.last[:message], "ack"
      assert_equal "", replacement.string
      session.close
      assert_equal "", replacement.string
    end
  end
end
