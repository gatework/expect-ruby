# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/interact_probe"
require "etc"

class InteractTest < ExpectTest
  def shell_session
    session = Expect.spawn("/bin/sh", "-i", env: { "PS1" => ScriptProbe::PROMPT, "ENV" => nil, "LC_ALL" => "C" },
                                            raw: true, write_timeout: 3)
    @sessions << session
    ScriptProbe::Runner.new(session).ready!
    InteractProbe.prepare(session)
    # Unlike SSH, the simulated remote shell shares the transport's PTY.
    # Only the local input terminal is changed by interact.
    session
  end

  def local_terminal
    master, slave = PTY.open
    @ios.push(master, slave)
    source = Expect.open(slave)
    @sessions << source
    [master, slave, source]
  end

  def socket_session
    local, peer = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(local, peer)
    session = Expect.open(local)
    @sessions << session
    [session, peer]
  end

  def test_changed_interact_regexp_does_not_match_previously_forwarded_input
    session, peer = socket_session
    input, keyboard = pipe_session
    keyboard.write("old")
    assert_nil session.interact(input: input.to_io, output: StringIO.new, escape: /STOP/, timeout: 0)
    assert_equal "old", peer.read_nonblock(100)

    assert_nil session.interact(input: input.to_io, output: StringIO.new, escape: /old/, timeout: 0)
    keyboard.write("oldtail")
    stopped = session.interact(input: input.to_io, output: StringIO.new, escape: /old/, timeout: 0.1)
    assert_same input.to_io, stopped.to_io
    assert_equal "tail", stopped.buffer
  end

  def test_same_interact_regexp_keeps_cross_call_history_and_unread_tail
    session, peer = socket_session
    input, keyboard = pipe_session
    keyboard.write("ST")
    assert_nil session.interact(input: input.to_io, output: StringIO.new, escape: /STOP/, timeout: 0)
    assert_equal "ST", peer.read_nonblock(100)

    keyboard.write("OPtail")
    stopped = session.interact(input: input.to_io, output: StringIO.new, escape: /STOP/, timeout: 0.1)
    assert_same input.to_io, stopped.to_io
    assert_equal "tail", stopped.buffer
    assert_nil session.interact(input: input.to_io, output: StringIO.new, escape: /STOP/, timeout: 0)
    assert_equal "tail", peer.read_nonblock(100)
  end

  def test_repeated_interact_keeps_split_crlf_on_the_same_terminal
    session, = socket_session
    master, slave, source = local_terminal
    session.buffer = "first\r"
    assert_nil session.interact(input: source, output: slave, timeout: 0)
    assert_equal "first\r", master.read_nonblock(100)

    session.buffer = "\nsecond"
    assert_nil session.interact(input: source, output: slave, timeout: 0)
    assert_equal "\nsecond", master.read_nonblock(100)
  end

  def test_changed_interact_regexp_preserves_pending_output_and_tail
    session, peer = socket_session
    input, keyboard = pipe_session
    loop { break if session.writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    keyboard.write("old")
    assert_nil session.interact(input:, output: StringIO.new, escape: /STOP/, timeout: 0)
    assert input.pending_output?
    input.buffer = "tail"
    loop { break if peer.read_nonblock(65_536, exception: false) == :wait_readable }

    assert_nil session.interact(input:, output: StringIO.new, escape: /old/, timeout: 0.01)
    refute input.pending_output?
    assert_empty input.buffer
    assert_equal "oldtail", peer.read_nonblock(100)
  end

  def test_real_terminal_handoff_ctrl_c_escape_and_resume
    session = shell_session
    log = StringIO.new
    session.transcript = log
    report = bounded(20) { InteractProbe.verify(session, user: Etc.getpwuid.name) }
    assert_equal 4, report[:cases].length
    assert(report[:cases].all? { |result| result[:passed] })
    assert report[:local_terminal_restored]
    assert report[:transport_terminal_restored]
    text = ScriptProbe.normalize(log.string)
    %w[AUTOMATION_RESUMED SECOND_HANDOFF_OK STDOUT_FIRST STDERR_SECOND].each do |line|
      assert_equal 1, text.scan(/^#{line}$/).length
    end
    refute_includes text, InteractProbe::TAIL
  end

  def test_timeout_restores_local_tty_and_session_settings
    session = shell_session
    _, slave, source = local_terminal
    saved = InteractProbe.configuration(source)
    state = InteractProbe.settings(session)
    source.on_sequence("original")
    source_state = InteractProbe.settings(source)
    assert_nil session.interact(input: source, escape: "\x1d", output: slave, timeout: 0.02)
    assert_equal saved, InteractProbe.configuration(source)
    assert_equal state, InteractProbe.settings(session)
    assert_equal source_state, InteractProbe.settings(source)
    assert session.alive?
  end

  def test_manual_typing_is_visible_before_enter_and_automation_resumes_without_echo
    session = shell_session
    InteractProbe.prepare(session, echo: true)
    master, slave, source = local_terminal
    screen = Expect.open(master, write_timeout: 3)
    @sessions << screen
    saved = InteractProbe.configuration(source)
    session.write("printf '\\n%s\\n' 'MANUAL_READY'\n")
    keyboard = Thread.new do
      ScriptProbe.check(screen.expect(/\r?\nMANUAL_READY\r?\n/, timeout: 3).matched?, "manual handoff was not ready")
      ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 3).matched?, "manual prompt missing")
      command = "printf 'VISIBLE_COMMAND\\n'"
      screen.write(command)
      ScriptProbe.check(screen.expect(command, timeout: 3).matched?, "typed command was invisible before Enter")
      screen.write("\n")
      ScriptProbe.check(screen.expect(/\r?\nVISIBLE_COMMAND\r?\n/, timeout: 3).matched?,
                        "manual command output missing")
      ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 3).matched?,
                        "manual command did not return to shell")
      screen.write(InteractProbe::ESCAPE)
      true
    rescue Exception # rubocop:disable Lint/RescueException -- Clean up terminal drivers even on Interrupt or SystemExit.
      begin
        screen.write(InteractProbe::ESCAPE)
      rescue StandardError
        nil
      end
      raise
    end
    keyboard.report_on_exception = false
    assert_same source, session.interact(input: source, escape: InteractProbe::ESCAPE, output: slave, timeout: 12)
    assert keyboard.join(2), "manual keyboard driver did not finish"
    assert keyboard.value
    assert_equal saved, InteractProbe.configuration(source)
    InteractProbe.prepare(session)
    log = StringIO.new
    session.transcript = log
    result = ScriptProbe::Runner.new(session).run("manual_resume", "printf 'RESUMED_WITHOUT_ECHO\\n'",
                                                  expected_status: 0, expected_output: "RESUMED_WITHOUT_ECHO\n")
    assert result[:passed]
    refute_includes log.string, "printf"
  ensure
    keyboard&.kill&.join if keyboard&.alive?
  end

  def test_interact_preserves_newline_processing_on_the_shared_local_terminal
    session = child(<<~'RUBY', raw: true)
      STDOUT.sync = true
      while STDIN.gets
        STDOUT.write("first\nsecond\r")
        STDIN.gets
        STDOUT.write("\nFW# ")
      end
    RUBY
    master, _, source = local_terminal
    screen = Expect.open(master, write_timeout: 3)
    @sessions << screen
    driver = Thread.new do
      screen.write("show\n")
      ScriptProbe.check(screen.expect("first\r\nsecond\r", timeout: 3).matched?,
                        "interact disabled output newline processing")
      screen.write("continue\n")
      ScriptProbe.check(screen.expect("\nFW# ", timeout: 3).matched?, "interact duplicated a split CRLF sequence")
      screen.write(InteractProbe::ESCAPE)
      true
    rescue Exception # rubocop:disable Lint/RescueException -- Release interact when the assertion fails.
      begin
        screen.write(InteractProbe::ESCAPE)
      rescue StandardError
        nil
      end
      raise
    end
    driver.report_on_exception = false

    assert_same source, session.interact(input: source, escape: InteractProbe::ESCAPE, output: source.to_io, timeout: 5)
    assert driver.join(2), "terminal driver did not finish"
    assert driver.value
  ensure
    driver&.kill&.join if driver&.alive?
  end

  def test_remote_eof_restores_input_terminal_and_keeps_borrowed_io_open
    session = child('STDIN.gets; print "FINAL_REMOTE_OUTPUT"', raw: true)
    _, slave, source = local_terminal
    saved = InteractProbe.configuration(source)
    output = StringIO.new
    session.write("go\n")
    assert_same session, session.interact(input: source, escape: "\x1d", output:, timeout: 3)
    assert_equal "FINAL_REMOTE_OUTPUT", output.string
    assert_equal saved, InteractProbe.configuration(source)
    refute slave.closed?
    assert_equal 0, session.wait(timeout: 1).exitstatus
  end

  def test_local_eof_returns_without_closing_remote_session
    session = shell_session
    source, writer = pipe_session
    writer.close
    assert_same source, session.interact(input: source, escape: "\x1d", output: StringIO.new, timeout: 2)
    assert session.alive?
    session.write("printf 'AFTER_LOCAL_EOF\\n'\n")
    assert_equal 1, session.expect(/AFTER_LOCAL_EOF\r?\n/, timeout: 2).number
  end

  def test_raw_false_preserves_input_terminal_during_interaction
    session, = socket_session
    _, slave, source = local_terminal
    original = InteractProbe.configuration(source)
    observed = nil
    session.on_sequence("STOP") do
      observed = InteractProbe.configuration(source)
      false
    end
    session.buffer = "STOP"

    assert_same session, session.interact(input: source, output: slave, raw: false, timeout: 1)
    assert_equal original, observed
    assert_equal original, InteractProbe.configuration(source)
  end

  def test_remote_callback_exception_restores_both_terminals
    session = shell_session
    _, slave, source = local_terminal
    local_mode = InteractProbe.configuration(source)
    remote_mode = InteractProbe.configuration(session)
    session.on_sequence("CALLBACK_FAILURE") { raise "test callback failed" }
    old_settings = InteractProbe.settings(session)
    session.write("printf 'CALLBACK_FAILURE\\n'\n")
    error = assert_raises(RuntimeError) { session.interact(input: source, escape: "\x1d", output: slave, timeout: 2) }
    assert_equal "test callback failed", error.message
    assert_equal local_mode, InteractProbe.configuration(source)
    assert_equal remote_mode, InteractProbe.configuration(session)
    assert_equal old_settings, InteractProbe.settings(session)
    assert session.alive?
  end

  def test_output_io_failure_restores_input_terminal
    session = shell_session
    _, slave, source = local_terminal
    saved = InteractProbe.configuration(source)
    output = StringIO.new
    output.close
    session.write("printf 'OUTPUT_FAILURE\\n'\n")
    assert_raises(IOError) { session.interact(input: source, escape: "\x1d", output:, timeout: 2) }
    assert_equal saved, InteractProbe.configuration(source)
    refute slave.closed?
  end
end
