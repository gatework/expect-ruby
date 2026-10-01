# frozen_string_literal: true

require_relative "script_probe"
require_relative "terminal_probe"

module InteractProbe
  ESCAPE = "\x1d".b.freeze
  TAIL = "LOCAL_ONLY_TAIL".b.freeze

  def self.configuration(session)
    TerminalProbe.configuration(session.to_io)
  end

  def self.settings(session)
    [session.outputs, session.logger, session.transcript, session.sequences.dup]
  end

  def self.prepare(session, echo: false)
    # The remote tty needs ISIG for Ctrl-C to reach its foreground process.
    # Manual interaction needs remote echo because the local input is raw.
    session.write("stty sane #{echo ? "echo" : "-echo"}; set +o emacs; set +o vi\n")
    ScriptProbe.check(session.expect(ScriptProbe::PROMPT, timeout: 5).matched?,
                      "terminal setup did not return to shell")
    session.clear_buffer
  end

  # A real local terminal slave is passed to interact; its master acts as a
  # keyboard/screen. Only interact reads the remote session during handoff.
  def self.verify(session, user:)
    master, slave = PTY.open
    source = Expect.open(slave)
    screen = Expect.open(master, write_timeout: 3)
    source.on_sequence("ORIGINAL_ESCAPE") { false }
    terminal_state = configuration(source)
    remote_state = configuration(session)
    source_settings = settings(source)
    remote_settings = settings(session)
    results = []
    checks = []

    run_cycle = lambda do |number, &actions|
      nonce = SecureRandom.hex(8)
      marker = "HANDOFF_#{nonce}"
      session.write("printf '\\n%s%s\\n' 'HANDOFF_' '#{nonce}'\n")
      worker = Thread.new do
        ScriptProbe.check(screen.expect(/#{Regexp.escape(marker)}\r?\n/, timeout: 5).matched?,
                          "handoff output did not reach local terminal")
        ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 5).matched?, "handoff prompt missing")
        ScriptProbe.check(!slave.echo?, "local input terminal did not disable echo")
        runner = ScriptProbe::Runner.new(screen)
        actions.call(runner)
        screen.write(ESCAPE + TAIL)
        runner.results
      rescue Exception # rubocop:disable Lint/RescueException -- Clean up terminal drivers even on Interrupt or SystemExit.
        begin
          screen.write(ESCAPE)
        rescue StandardError
          nil
        end
        raise
      end
      worker.report_on_exception = false
      begin
        returned = session.interact(input: source, escape: ESCAPE, output: slave, timeout: 20)
        ScriptProbe.check(worker.join(2), "keyboard driver did not finish")
        results.concat(worker.value)
        ScriptProbe.check(returned.equal?(source), "interact did not return on the local escape")
        ScriptProbe.check(source.clear_buffer == TAIL, "escape tail was lost or forwarded to remote")
        ScriptProbe.check(session.alive?, "local escape closed the remote process")
        ScriptProbe.check(configuration(source) == terminal_state, "local terminal settings were not restored")
        ScriptProbe.check(configuration(session) == remote_state,
                          "remote transport terminal settings were not restored")
        ScriptProbe.check(settings(source) == source_settings,
                          "local outputs/logging/escape handlers were not restored")
        ScriptProbe.check(settings(session) == remote_settings,
                          "remote outputs/logging/escape handlers were not restored")
        checks << "cycle_#{number}_escape_tail_and_restore"
      ensure
        worker.kill.join if worker.alive?
      end
    end

    run_cycle.call(1) do |runner|
      runner.run("interactive_identity", "printf 'USER='; id -un; test -t 0 && printf 'TTY_OK\\n'",
                 expected_status: 0, expected_output: "USER=#{user}\nTTY_OK\n")
      runner.run_file(
        File.join(ScriptProbe::FIXTURES, "02_output.sh"),
        expected_status: 0,
        expected_output: "STDOUT_FIRST\nSTDERR_SECOND\n中文输出：日志验证\nSTDOUT_LAST\n"
      )
      nonce = SecureRandom.hex(8)
      # An actual foreground shell handles the forwarded Ctrl-C. Readiness is
      # acknowledged before sending the control byte, without a timing guess.
      script = "trap 'printf \"INT_HANDLED_#{nonce}\\n\"; exit 0' INT; " \
               "printf 'INT_READY_#{nonce}\\n'; while :; do sleep 1; done"
      screen.write("/bin/sh -c #{Shellwords.escape(script)}\n")
      ScriptProbe.check(screen.expect(/INT_READY_#{nonce}\r?\n/, timeout: 5).matched?,
                        "foreground command did not become ready")
      screen.write("\x03")
      ScriptProbe.check(screen.expect(/INT_HANDLED_#{nonce}\r?\n/, timeout: 5).matched?,
                        "Ctrl-C did not reach remote foreground process")
      ScriptProbe.check(screen.expect(ScriptProbe::PROMPT, timeout: 5).matched?, "shell did not recover after Ctrl-C")
      checks << "ctrl_c_forwarded_to_remote"
    end

    resumed = ScriptProbe::Runner.new(session)
    resumed.run("expect_after_interact", "printf 'AUTOMATION_RESUMED\\n'", expected_status: 0,
                                                                           expected_output: "AUTOMATION_RESUMED\n")
    results.concat(resumed.results)
    run_cycle.call(2) do |runner|
      runner.run("interact_again", "printf 'SECOND_HANDOFF_OK\\n'", expected_status: 0,
                                                                    expected_output: "SECOND_HANDOFF_OK\n")
    end
    checks.push("keyboard_to_remote", "remote_to_screen", "utf8_stdout_stderr",
                "raw_mode_during_interact", "expect_resume", "reenter_interact")
    { cases: results, checks:,
      local_tty: slave.path, local_terminal_restored: true, transport_terminal_restored: true }
  ensure
    source&.close
    screen&.close
    [master, slave].compact.each { |io| io.close unless io.closed? }
  end
end
