# frozen_string_literal: true

require_relative "test_helper"

class ResponderTest < ExpectTest
  def test_processes_prompts_in_input_order_and_preserves_the_tail
    session, = pipe_session
    session.buffer = "output:first?second?first?DONEtail"
    sent = []
    rules = Expect::Responder.new do |responses|
      responses.on("second?") { |source| sent << source.match }
      responses.on("first?") { |source| sent << source.match }
    end
    result = rules.expect(session, "DONE", timeout: 1)
    assert_equal %w[first? second? first?], sent
    assert_equal "DONE", result.match
    assert_equal "tail", session.buffer
  end

  def test_completion_at_the_same_position_takes_precedence
    session, = pipe_session
    session.buffer = "DONEquestion?"
    rules = Expect::Responder.new.on("DONE") { flunk "completion was answered" }
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal "question?", session.buffer
  end

  def test_same_position_rules_keep_declaration_priority
    session, = pipe_session
    session.buffer = "question?DONE"
    seen = []
    rules = Expect::Responder.new do |responses|
      responses.on(/question\?/) { seen << 1 }
      responses.on("question?") { seen << 2 }
    end
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal [1], seen
  end

  def test_repeated_real_pty_confirmation_paging_and_dynamic_captures
    session = child(<<~'SCRIPT', raw: true, timeout: 2, write_timeout: 1)
      2.times do
        print "Confirm [y/N]: "
        abort "bad confirmation" unless STDIN.gets == "y\n"
        print "--More--"
        abort "bad page key" unless STDIN.read(1) == " "
        print "Code 42: "
        abort "bad dynamic reply" unless STDIN.gets == "42\n"
        puts "DONE"
      end
    SCRIPT
    rules = Expect::Responder.new do |responses|
      responses.on("--More--", reply: " ", limit: 1)
      responses.on(/Code (\d+): /, limit: 1) { |source| source.puts(source.captures.first) }
      responses.on("Confirm [y/N]: ", reply: "y\n", limit: 1)
    end
    2.times { assert rules.expect(session, "DONE").matched? }
    assert session.soft_close(timeout: 2).success?
  end

  def test_limit_is_checked_before_an_extra_response_and_resets_next_wait
    session, = pipe_session
    sent = []
    rules = Expect::Responder.new.on("?", limit: 1) { sent << :reply }
    session.buffer = "??DONE"
    assert_raises(Expect::Responder::ResponseError) { rules.expect(session, "DONE", timeout: 1) }
    assert_equal [:reply], sent
    session.buffer = "?DONE"
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal %i[reply reply], sent
  end

  def test_zero_width_patterns_do_not_send
    session, = pipe_session
    session.buffer = "text"
    rules = Expect::Responder.new.on(/(?=text)/) { flunk "empty prompt was answered" }
    assert_raises(Expect::Responder::ResponseError) { rules.expect(session, :eof, timeout: 1) }
  end

  def test_eof_and_timeout_are_results_and_preserve_transcript
    session, producer = pipe_session
    transcript = StringIO.new
    session.transcript = transcript
    rules = Expect::Responder.new.on("confirm?") { nil }
    producer.write("before confirm? after")
    producer.close
    result = rules.expect(session, :eof, timeout: 1)
    assert result.eof?
    assert_equal " after", result.before
    assert_equal "before confirm? after", transcript.string
    waiting, = pipe_session
    assert rules.expect(waiting, "DONE", timeout: 0).timeout?
  end

  def test_responses_do_not_extend_timeout
    session = child('loop { print "?"; sleep 0.005 }', raw: true)
    rules = Expect::Responder.new.on("?") { nil }
    bounded(1) do
      start = Expect.monotonic
      assert rules.expect(session, "DONE", timeout: 0.06).timeout?
      assert_operator Expect.monotonic - start, :<, 0.5
    end
  end

  def test_expired_deadline_does_not_answer_buffered_prompts
    session, = pipe_session
    session.buffer = "?DONE"
    rules = Expect::Responder.new.on("?") { flunk "expired reply" }
    assert rules.expect(session, "DONE", deadline: Expect.monotonic).timeout?
    assert_equal "?DONE", session.buffer
  end

  def test_rule_edits_during_a_callback_only_affect_later_waits
    session, = pipe_session
    rules = Expect::Responder.new
    seen = []
    rules.on("first?") { rules.on("second?") { seen << :second } }
    session.buffer = "first?second?DONE"
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_empty seen
    session.buffer = "second?DONE"
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal [:second], seen
  end

  def test_write_failure_is_not_retried_or_wrapped
    session, = pipe_session
    session.buffer = "?DONE"
    error = Expect::WriteTimeout.new(bytes_written: 1)
    writes = 0
    session.define_singleton_method(:write) do |_data|
      writes += 1
      raise error
    end
    rules = Expect::Responder.new.on("?", reply: "yes\n")
    assert_same error, assert_raises(Expect::WriteTimeout) { rules.expect(session, "DONE", timeout: 1) }
    assert_equal 1, writes
    assert_equal "DONE", session.buffer
  end

  def test_rule_strings_are_copied_and_reply_is_written_verbatim
    reader, producer = IO.pipe
    reply_reader, reply_writer = IO.pipe
    @ios.push(reader, producer, reply_reader, reply_writer)
    session = Expect.open(reader, writer: reply_writer)
    @sessions << session
    pattern = +"?"
    reply = +"secret\r"
    rules = Expect::Responder.new.on(pattern, reply:, limit: 1)
    pattern.replace("other")
    reply.replace("changed")
    session.buffer = "?DONE"
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal "secret\r", reply_reader.read_nonblock(7)
    refute_includes rules.inspect, "secret"
  end

  def test_registration_validation_and_freeze
    rules = Expect::Responder.new
    [nil, :eof, "", 123].each do |pattern|
      assert_raises(ArgumentError) { rules.on(pattern, reply: "y") }
    end
    [0, -1, 1.5, "1", false].each do |limit|
      assert_raises(ArgumentError) { rules.on("?", reply: "y", limit:) }
    end
    assert_raises(ArgumentError) { rules.on("?") }
    assert_raises(ArgumentError) { rules.on("?", reply: false) }
    assert_raises(ArgumentError) { rules.on("?", reply: "y") { nil } }
    assert_same rules, rules.on("?", reply: "")
    rules.freeze
    assert_raises(FrozenError) { rules.on("?", reply: "y") }
    assert_raises(ArgumentError) { rules.expect(Object.new) }
  end

  def test_fragmented_utf8_prompt
    session, producer = pipe_session
    bytes = "确认?DONE".b
    seen = []
    background do
      producer.write(bytes.byteslice(0, 2))
      sleep 0.01
      producer.write(bytes.byteslice(2..))
    end
    rules = Expect::Responder.new.on(/确认\?/u) { |source| seen << source.match }
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert_equal ["确认?".b], seen
  end

  def test_reply_and_received_secret_use_existing_redaction
    session = child('print "Password?"; password = STDIN.gets.strip; puts "received:" + password + " DONE"', raw: true)
    transcript = StringIO.new
    diagnostics = StringIO.new
    session.transcript = transcript
    session.logger = Logger.new(diagnostics, level: Logger::DEBUG)
    session.redact("secret")
    rules = Expect::Responder.new.on("Password?", reply: "secret\n", limit: 1)
    assert rules.expect(session, "DONE", timeout: 1).matched?
    assert session.soft_close(timeout: 1).success?
    refute_includes transcript.string, "secret"
    refute_includes diagnostics.string, "secret"
    assert_includes transcript.string, "[FILTERED]"
    assert_includes diagnostics.string, "[FILTERED]"
  end

  def test_interaction_tail_is_restored_even_when_response_raises
    session, = pipe_session
    buffer = +"?DONEtail".b
    session.interaction_buffer = buffer
    error = RuntimeError.new("response failed")
    rules = Expect::Responder.new.on("?") { raise error }
    assert_same error, assert_raises(RuntimeError) { rules.expect(session, "DONE", timeout: 1) }
    assert_same buffer, session.interaction_buffer
    assert_equal "DONEtail", buffer
    assert_empty session.buffer
  end

  def test_terminal_rules_cannot_add_another_source
    session, = pipe_session
    other, = pipe_session
    session.buffer = "?"
    other.buffer = "DONE"
    rules = Expect::Responder.new.on("?") { flunk "invalid sources performed IO" }
    assert_raises(ArgumentError) do
      rules.expect(session) { |patterns| patterns.on("DONE", from: other) }
    end
    assert_equal "?", session.buffer
    assert_equal "DONE", other.buffer
  end

  def test_terminal_dsl_and_ambiguous_registration
    session, = pipe_session
    session.buffer = "?DONE"
    rules = Expect::Responder.new.on("?") { nil }
    assert rules.expect(session, timeout: 1) { on("DONE") }.matched?
    assert_raises(ArgumentError) { rules.expect(session, "DONE") { on("other") } }
  end
end
