# frozen_string_literal: true

require "digest"
require "securerandom"
require "shellwords"
require_relative "../../lib/expect/pty"

# Shared by the real SSH check and the automatic local-PTY tests. This is a
# test harness for a POSIX shell, not a network-device command abstraction.
module ScriptProbe
  PROMPT = "EXPECT_SCRIPT_PROMPT> "
  FIXTURES = File.expand_path("../fixtures/ssh_scripts", __dir__)

  class Failure < StandardError; end

  def self.check(condition, message)
    raise Failure, message unless condition
  end

  def self.normalize(bytes)
    bytes.gsub("\r\n", "\n").b
  end

  class Runner
    attr_reader :session, :results

    def initialize(session, timeout: 5)
      @session = session
      @timeout = timeout
      @results = []
    end

    def ready!
      result = session.expect(PROMPT, timeout: @timeout)
      ScriptProbe.check(result.matched?, "shell prompt missing (#{result.error})")
      # Avoid terminal echo being mistaken for script output or leaking the
      # test's wrapper command into the output we verify.
      # Interactive shells may interpret high-bit bytes as readline commands
      # in a C locale. Disable editing for literal script transmission.
      session.write("stty -echo; set +o emacs; set +o vi\n")
      result = session.expect(PROMPT, timeout: @timeout)
      ScriptProbe.check(result.matched?, "shell setup failed (#{result.error})")
      session.clear_buffer
      self
    end

    def run_file(path, expected_status:, expected_output:)
      run(File.basename(path), File.binread(path), expected_status:, expected_output:)
    end

    def run(name, script, expected_status:, expected_output:)
      nonce = SecureRandom.hex(12)
      start_marker = "PROBE_BEGIN_#{nonce}"
      end_marker = "PROBE_END_#{nonce}"
      digest = Digest::SHA256.hexdigest(script)
      # Quote once for the remote shell without inserting backslashes between
      # UTF-8 bytes (File.binread returns an ASCII-8BIT string).
      quoted_script = "'#{script.gsub("'", %q('"'"'))}'"
      # Inputs are logged deliberately as metadata: Expect's automatic log
      # records received bytes, not sends. Never include authentication here.
      session.write_transcript("\n[SEND] #{name} sha256=#{digest}\n")
      command = "printf '\\n%s%s\\n' 'PROBE_BEGIN_' '#{nonce}'; " \
                "/bin/sh -c #{quoted_script}; probe_status=$?; " \
                "printf '\\n%s%s:%s\\n' 'PROBE_END_' '#{nonce}' \"$probe_status\"\n"
      session.write(command)
      started = session.expect(/(?:\A|\r?\n)#{Regexp.escape(start_marker)}\r?\n/, timeout: @timeout)
      ScriptProbe.check(started.matched?, "#{name}: begin marker missing (#{started.error})")
      ended = session.expect(/(?:\A|\r?\n)#{Regexp.escape(end_marker)}:(\d+)\r?\n/, timeout: @timeout)
      ScriptProbe.check(ended.matched?, "#{name}: script did not finish (#{ended.error})")
      output = ScriptProbe.normalize(ended.before)
      status = Integer(ended.captures.fetch(0), 10)
      # Wait for the shell before starting another script, including when the
      # prior script exited nonzero. Each script runs in its own subshell.
      prompt = session.expect(PROMPT, timeout: @timeout)
      ScriptProbe.check(prompt.matched?, "#{name}: shell did not recover (#{prompt.error})")
      session.write_transcript("\n[EXIT] #{name} status=#{status}\n")
      passed = status == expected_status && output == expected_output.b
      result = { name:, sha256: digest, status:, expected_status:,
                 output: output.dup.force_encoding(Encoding::UTF_8), passed: }
      results << result
      ScriptProbe.check(status == expected_status, "#{name}: exit #{status}, expected #{expected_status}")
      ScriptProbe.check(output == expected_output.b, "#{name}: output differs from fixture expectation")
      result
    end

    def finish!
      # The last bytes arrive while soft_close drains the session. No expect
      # call is made after this send, so the log proves shutdown draining.
      session.write("sleep 0.1; printf '%s%s\\n' 'SESSION_' 'FINAL_TAIL'; exit 0\n")
      session.soft_close(timeout: 3)
      ScriptProbe.check(session.closed? && session.exit_code&.zero?, "shell did not exit cleanly")
    end
  end

  # Run all script fixtures in one session, then verify the persisted log.
  # An explicit nonzero fixture is an expected success of the test harness.
  def self.verify_file_session(runner, path, user:)
    session = runner.session
    # With SSH, the remote TTY differs from the local PTY. Obtain it using an
    # independent command, then demand an exact identity fixture response.
    session.write("printf '\\n%s' 'TTY_PROBE='; tty\n")
    tty = session.expect(%r{(?:\A|\n)TTY_PROBE=(/dev/[^\r\n]+)\r?\n}, timeout: 5)
    check(tty.matched?, "remote TTY probe failed")
    terminal = tty.captures.fetch(0)
    check(session.expect(PROMPT, timeout: 5).matched?, "TTY probe did not return to shell")

    # The caller allocates a fresh private directory; exercise truncation only
    # on this new test file, never on an existing user's log.
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("OLD_TEST_CONTENT\n") }
    cases = [
      ["01_identity.sh", 0, "USER=#{user}\nTTY=#{terminal}\nIDENTITY_OK\n"],
      ["02_output.sh", 0, "STDOUT_FIRST\nSTDERR_SECOND\n中文输出：日志验证\nSTDOUT_LAST\n"],
      ["03_delayed.sh", 0, "DELAY_BEGIN\nDELAY_MIDDLE\nDELAY_END\n"],
      ["04_failure.sh", 7, "EXPECTED_FAILURE\n"],
      ["05_recovery.sh", 0, "RECOVERY_OK\nVALUE=42\n"]
    ]
    File.open(path, "wb") do |transcript|
      session.transcript = transcript
      cases.each do |name, status, output|
        runner.run_file(File.join(FIXTURES, name), expected_status: status, expected_output: output)
        # Read while the writer is open to prove writes are immediately visible.
        live = normalize(File.binread(path))
        check(live.include?(output.b), "#{name}: live log is missing output")
        check(live.include?("[EXIT] #{name} status=#{status}\n"), "#{name}: live exit annotation missing")
      end
      session.transcript = nil
      check(!transcript.closed?, "disabling transcript closed the caller's file")
    ensure
      session.transcript = nil
    end
    before_disabled = File.binread(path)
    runner.run("logging_disabled", "printf 'UNLOGGED_OUTPUT\\n'\n", expected_status: 0,
                                                                    expected_output: "UNLOGGED_OUTPUT\n")
    check(File.binread(path) == before_disabled, "disabled logger still wrote data")

    # The caller chooses append mode, retaining every preceding command.
    File.open(path, "ab") do |transcript|
      session.transcript = transcript
      runner.run("logging_resumed", "printf 'APPEND_OK\\n'\n", expected_status: 0, expected_output: "APPEND_OK\n")
      runner.finish!
      check(!transcript.closed?, "closing the session closed the caller's file")
    ensure
      session.transcript = nil
    end
    bytes = File.binread(path)
    check(bytes.start_with?(before_disabled), "append mode overwrote previous log bytes")
    text = normalize(bytes)
    check(!text.include?("OLD_TEST_CONTENT") && !text.include?("UNLOGGED_OUTPUT"),
          "truncated or disabled data leaked into log")
    position = -1
    cases.each do |name, status, output|
      sent = text.index("[SEND] #{name} ")
      exited = text.index("[EXIT] #{name} status=#{status}\n")
      check(sent && exited && sent > position && exited > sent, "#{name}: incorrect log execution order")
      check(text.scan(Regexp.new(Regexp.escape(output.b), Regexp::NOENCODING)).length == 1,
            "#{name}: output missing or duplicated")
      position = exited
    end
    check(text.include?("APPEND_OK\n"), "resumed logging lost output")
    check(text.scan("SESSION_FINAL_TAIL\n").length == 1, "shutdown lost or duplicated final output")
    { cases: runner.results, remote_tty: terminal, log_bytes: bytes.bytesize,
      log_sha256: Digest::SHA256.hexdigest(bytes),
      checks: %w[exact_output execution_order live_flush stdout_stderr utf8 nonzero_recovery
                 truncate disable append eof_drain] }
  end
end
