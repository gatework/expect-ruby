# frozen_string_literal: true

require_relative "interact_probe"

# Drive the actual host and join CLIs through two independent local terminals.
# No Minitest dependency, SSH service, password, or external user is needed.
module KibitzProbe
  EXAMPLE = File.expand_path("../../examples/kibitz/kibitz.rb", __dir__)

  class Pair
    attr_reader :host, :guest, :socket_path, :log_path

    def initialize(directory, noproc: false, host_flags: [], guest_flags: [])
      @sessions = []
      @terminal_modes = {}
      @log_path = File.join(directory, "session.log")
      command = noproc ? ["--noproc"] : ["--", "env", "ENV=", "PS1=#{ScriptProbe::PROMPT}", "LC_ALL=C", "/bin/sh", "-i"]
      @host = spawn_cli("--timeout", "15", "--log", log_path, *host_flags, *command)
      invitation = host.expect(%r{--join (/tmp/expect-kibitz-[^\r\n ]+/peer\.sock)}, timeout: 5)
      ScriptProbe.check(invitation.matched?, "host did not print the join command")
      @socket_path = invitation.captures.first
      ScriptProbe.check(File.stat(File.dirname(socket_path)).mode & 0o777 == 0o700, "socket directory is not private")
      ScriptProbe.check(File.stat(socket_path).mode & 0o777 == 0o600, "socket is not private")
      @guest = spawn_cli("--join", socket_path, "--timeout", "15", *guest_flags)
      [host, guest].each { |terminal| expect(terminal, /Kibitz connected\.[^\r\n]*\r?\n/) }
      ScriptProbe.check(!host.to_io.echo? && !guest.to_io.echo?, "connected banner preceded terminal readiness")
    rescue Exception # rubocop:disable Lint/RescueException -- Clean up terminal drivers even on Interrupt or SystemExit.
      close
      raise
    end

    def spawn_cli(*)
      terminal = Expect::Session.new(write_timeout: 3)
      @sessions << terminal
      @terminal_modes[terminal] = InteractProbe.configuration(terminal)
      terminal.spawn(RbConfig.ruby, EXAMPLE, *)
      terminal
    end

    def expect(terminal, pattern)
      result = terminal.expect(pattern, timeout: 5)
      ScriptProbe.check(result.matched?,
                        "#{terminal.equal?(host) ? "host" : "guest"} missing #{pattern.inspect} (#{result.error})")
      result
    end

    def both(pattern)
      [host, guest].map { |terminal| expect(terminal, pattern) }
    end

    def prepare_shell
      ScriptProbe::Runner.new(host).ready!
      host.write("printf '\\n%s%s\\n' 'KIBITZ_' 'READY'\n")
      both(/\r?\nKIBITZ_READY\r?\n/)
      both(ScriptProbe::PROMPT)
    end

    def command(terminal, command, output)
      terminal.write(command, "\n")
      both(output)
      both(ScriptProbe::PROMPT)
    end

    def finish!(expected_host_status: 0)
      [host, guest].each do |terminal|
        result = terminal.expect(:eof, timeout: 5)
        ScriptProbe.check(result.eof?, "kibitz did not reach EOF")
        status = terminal.wait(timeout: 2)
        expected = terminal.equal?(host) ? expected_host_status : 0
        ScriptProbe.check(status && status.exitstatus == expected,
                          "kibitz exit status was #{status&.exitstatus.inspect}, expected #{expected}")
        ScriptProbe.check(InteractProbe.configuration(terminal) == @terminal_modes.fetch(terminal),
                          "terminal mode was not restored")
      end
      ScriptProbe.check(!File.exist?(File.dirname(socket_path)), "socket directory was not cleaned up")
      ScriptProbe.check(File.stat(log_path).mode & 0o777 == 0o600, "log permissions changed")
      self
    end

    def close
      @sessions&.reverse_each(&:close)
    end
  end

  def self.shared_shell(directory)
    pair = Pair.new(directory)
    # With local terminals raw, the process's terminal supplies typed echo.
    pair.both(ScriptProbe::PROMPT)
    pair.host.write("printf 'VISIBLE_TYPING\\n'")
    pair.both("printf 'VISIBLE_TYPING\\n'")
    pair.host.write("\n")
    pair.both(/\r?\nVISIBLE_TYPING\r?\n/)
    pair.both(ScriptProbe::PROMPT)
    # ready! expects an outstanding prompt; use a fresh one after the echo check.
    pair.host.write("\n")
    pair.prepare_shell
    pair.command(pair.host, "shared_value=42; printf 'HOST_SET\\n'", /HOST_SET\r?\n/)
    pair.command(pair.guest, "printf 'SHARED=%s\\n' \"$shared_value\"", /SHARED=42\r?\n/)
    pair.command(pair.guest, "printf '中文输出\\n'; printf 'GUEST_STDERR\\n' >&2", /中文输出\r?\nGUEST_STDERR\r?\n/)
    pair.command(pair.host, "/bin/sh -c 'exit 7'; printf 'RECOVERED=%s\\n' \"$?\"", /RECOVERED=7\r?\n/)
    script = "trap 'printf \"INT_HANDLED\\n\"; exit 0' INT; printf 'INT_READY\\n'; while :; do sleep 1; done"
    pair.host.write("/bin/sh -c #{Shellwords.escape(script)}\n")
    pair.both(/INT_READY\r?\n/)
    pair.guest.write("\x03")
    pair.both(/INT_HANDLED\r?\n/)
    pair.both(ScriptProbe::PROMPT)
    pair.guest.write("printf 'FINAL_TAIL\\n'; exit 0\n")
    pair.both(/FINAL_TAIL\r?\n/)
    pair.finish!
    log = ScriptProbe.normalize(File.binread(pair.log_path))
    %w[HOST_SET SHARED=42 GUEST_STDERR RECOVERED=7 INT_READY INT_HANDLED FINAL_TAIL].each do |line|
      # With echo disabled the output can follow a prompt on the same line.
      ScriptProbe.check(log.scan("#{line}\n").length == 1, "#{line} missing or duplicated in log")
    end
    { name: "shared_shell", passed: true,
      checks: %w[visible_typing both_keyboards shared_shell_state broadcast_stdout_stderr utf8 nonzero_recovery
                 guest_ctrl_c process_eof final_tail unique_log terminal_restore socket_cleanup] }
  ensure
    pair&.close
  end

  def self.direct(directory, ending: :host)
    custom = ending == :host ? ["--escape", "STOP"] : []
    pair = Pair.new(directory, noproc: true, host_flags: custom)
    pair.host.write("HOST_MESSAGE")
    pair.expect(pair.guest, "HOST_MESSAGE")
    ScriptProbe.check(pair.host.expect("HOST_MESSAGE", timeout: 0.02).timeout?, "noproc echoed the sender's input")
    pair.guest.write("中文回信")
    pair.expect(pair.host, "中文回信")
    ScriptProbe.check(pair.guest.expect("中文回信", timeout: 0.02).timeout?, "noproc echoed the guest's input")
    if ending == :host
      pair.host.write("prefixST")
      pair.expect(pair.guest, "prefix")
      ScriptProbe.check(pair.guest.expect("ST", timeout: 0.02).timeout?, "split escape prefix leaked to peer")
      pair.host.write("OPLOCAL_TAIL")
    else
      pair.guest.write(InteractProbe::ESCAPE)
    end
    pair.finish!
    ScriptProbe.check(!pair.guest.before.include?("LOCAL_TAIL") && !pair.guest.before.include?("STOP"),
                      "local escape leaked to peer")
    { name: "noproc_#{ending}_escape", passed: true,
      checks: %w[two_way_bytes utf8 no_local_echo escape peer_eof terminal_restore socket_cleanup] }
  ensure
    pair&.close
  end

  def self.noescape(directory)
    pair = Pair.new(directory, noproc: true, host_flags: ["--noescape"])
    pair.host.write("before\x1dafter")
    pair.expect(pair.guest, "before\x1dafter")
    pair.guest.write(InteractProbe::ESCAPE)
    pair.finish!
    { name: "noescape", passed: true, checks: %w[control_byte_forwarded peer_eof terminal_restore socket_cleanup] }
  ensure
    pair&.close
  end

  def self.process_failure(directory)
    pair = Pair.new(directory)
    pair.prepare_shell
    pair.host.write("exit 7\n")
    pair.finish!(expected_host_status: 7)
    { name: "process_failure", passed: true, checks: %w[nonzero_exit_status peer_eof terminal_restore socket_cleanup] }
  ensure
    pair&.close
  end

  def self.relay_timeout(directory)
    pair = Pair.new(directory, noproc: true, host_flags: ["--timeout", "1"])
    pair.finish!(expected_host_status: 1)
    ScriptProbe.check(pair.host.before.include?("Kibitz ended (timeout)."), "relay did not report its timeout")
    { name: "relay_timeout", passed: true, checks: %w[timeout_status peer_eof terminal_restore socket_cleanup] }
  ensure
    pair&.close
  end
end
