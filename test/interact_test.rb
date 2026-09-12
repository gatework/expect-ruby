# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/interact_probe"
require "etc"

class InteractTest < ExpectTest
  def shell_session
    session = Expect.spawn("/bin/sh", "-i", env: { "PS1" => ScriptProbe::PROMPT, "ENV" => nil, "LC_ALL" => "C" },
                                            raw_pty: true, log_stdout: false, write_timeout: 3)
    @sessions << session
    ScriptProbe::Runner.new(session).ready!
    InteractProbe.prepare(session)
    # Unlike SSH, the simulated remote shell shares the transport's PTY.
    # Keep its canonical/ISIG settings while interact raws the local keyboard.
    session.raw_terminal = false
    session
  end

  def local_terminal
    master, slave = PTY.open
    @ios.push(master, slave)
    source = Expect.open(slave)
    @sessions << source
    [master, slave, source]
  end

  def test_real_terminal_handoff_ctrl_c_escape_and_resume
    session = shell_session
    log = StringIO.new
    session.log_to(log)
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
      ScriptProbe.check(screen.expect(/\r?\nMANUAL_READY\r?\n/, timeout: 3), "manual handoff was not ready")
      ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 3), "manual prompt missing")
      command = "printf 'VISIBLE_COMMAND\\n'"
      screen.write(command)
      ScriptProbe.check(screen.expect(command, timeout: 3), "typed command was invisible before Enter")
      screen.write("\n")
      ScriptProbe.check(screen.expect(/\r?\nVISIBLE_COMMAND\r?\n/, timeout: 3), "manual command output missing")
      ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 3), "manual command did not return to shell")
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
    session.log_to(log)
    result = ScriptProbe::Runner.new(session).run("manual_resume", "printf 'RESUMED_WITHOUT_ECHO\\n'",
                                                  expected_status: 0, expected_output: "RESUMED_WITHOUT_ECHO\n")
    assert result[:passed]
    refute_includes log.string, "printf"
  ensure
    keyboard&.kill&.join if keyboard&.alive?
  end

  def test_remote_eof_restores_input_terminal_and_keeps_borrowed_io_open
    session = child('STDIN.gets; print "FINAL_REMOTE_OUTPUT"', raw_pty: true)
    _, slave, source = local_terminal
    saved = InteractProbe.configuration(source)
    output = StringIO.new
    session.write("go\n")
    assert_same session, session.interact(input: source, escape: "\x1d", output: output, timeout: 3)
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
    assert_equal 1, session.expect(/AFTER_LOCAL_EOF\r?\n/, timeout: 2)
  end

  def test_remote_callback_exception_restores_both_terminals
    session = shell_session
    _, slave, source = local_terminal
    local_mode = InteractProbe.configuration(source)
    remote_mode = InteractProbe.configuration(session)
    old_settings = InteractProbe.settings(session)
    session.on_sequence("CALLBACK_FAILURE") { raise "test callback failed" }
    session.write("printf 'CALLBACK_FAILURE\\n'\n")
    error = assert_raises(RuntimeError) { session.interact(input: source, escape: "\x1d", output: slave, timeout: 2) }
    assert_equal "test callback failed", error.message
    assert_equal local_mode, InteractProbe.configuration(source)
    assert_equal remote_mode, InteractProbe.configuration(session)
    assert_equal old_settings[0..3], InteractProbe.settings(session)[0..3]
    assert session.alive?
  end

  def test_output_io_failure_restores_input_terminal
    session = shell_session
    _, slave, source = local_terminal
    saved = InteractProbe.configuration(source)
    output = StringIO.new
    output.close
    session.write("printf 'OUTPUT_FAILURE\\n'\n")
    assert_raises(IOError) { session.interact(input: source, escape: "\x1d", output: output, timeout: 2) }
    assert_equal saved, InteractProbe.configuration(source)
    refute slave.closed?
  end
end
