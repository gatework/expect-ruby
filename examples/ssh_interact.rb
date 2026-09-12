# frozen_string_literal: true

# Run from the checkout or the unpacked gem. Test helpers use only standard
# libraries; Minitest is not needed for this live SSH example.
require "io/console"
require "json"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../test/support/interact_probe"

if ARGV.delete("--help")
  puts <<~HELP
    Usage: ruby examples/ssh_interact.rb [--auto]

    Default: SSH login with visible typing; Ctrl-] returns to expect, exit ends SSH.
    --auto:  Drive a real local PTY to verify commands, Ctrl-C, Ctrl-] and reentry.

    Environment: SSH_HOST (127.0.0.1), SSH_USER (current user), SSH_PORT (22),
                 SSH_KNOWN_HOSTS, EXPECT_PASSWORD, EXPECT_LOG_DIR.
    Password input is hidden. Non-loopback hosts require SSH_KNOWN_HOSTS.
    Logs and JSON reports default to tmp/ssh-interact/ in this project.
  HELP
  exit
end
automatic = !ARGV.delete("--auto").nil?
abort "unknown arguments: #{ARGV.join(" ")} (use --help)" unless ARGV.empty?
abort "manual interact requires a terminal; use --auto for unattended testing" unless automatic || $stdin.tty?

host = ENV.fetch("SSH_HOST", "127.0.0.1")
user = ENV.fetch("SSH_USER", ENV.fetch("USER", "crate"))
port = Integer(ENV.fetch("SSH_PORT", "22"), 10)
ScriptProbe.check((1..65_535).cover?(port), "SSH_PORT must be between 1 and 65535")
ScriptProbe.check([host, user].none? do |value|
  value.empty? || value.start_with?("-") || value.match?(/[\s\x00]/)
end, "invalid SSH host or user")
known_hosts = ENV.fetch("SSH_KNOWN_HOSTS", nil)
ScriptProbe.check(known_hosts || %w[127.0.0.1 ::1 localhost].include?(host),
                  "SSH_KNOWN_HOSTS is required for remote hosts")

password = ENV.delete("EXPECT_PASSWORD")&.dup
unless password
  $stderr.print("SSH password: ")
  password = ($stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets)&.chomp
  $stderr.puts
end
ScriptProbe.check(password && !password.empty? && !password.match?(/[\r\n\x00]/), "a single-line password is required")
base = File.expand_path(ENV.fetch("EXPECT_LOG_DIR", File.expand_path("../tmp/ssh-interact", __dir__)))
FileUtils.mkdir_p(base)
directory = Dir.mktmpdir("#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-", base)
log_path = File.join(directory, "session.log")
report_path = File.join(directory, "report.json")
report = { mode: automatic ? "automatic" : "manual", host: host, port: port, user: user,
           started_at: Time.now.utc.iso8601, passed: false, cases: [], checks: [] }
session = nil
local_terminal = nil

begin
  Dir.mktmpdir("expect-known-hosts-") do |temporary|
    policy = known_hosts ? "yes" : "accept-new"
    hosts_path = known_hosts || File.join(temporary, "known_hosts")
    args = ["ssh", "-F", "/dev/null", "-tt", "-p", port.to_s,
            "-o", "ConnectTimeout=5", "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
            "-o", "StrictHostKeyChecking=#{policy}", "-o", "UserKnownHostsFile=#{hosts_path}",
            "-l", user, host, "env ENV= PS1=#{Shellwords.escape(ScriptProbe::PROMPT)} /bin/sh -i"]
    session = Expect.spawn(*args, raw_pty: true, log_stdout: false, log_listeners: false,
                                  debug_level: 0, write_timeout: 5)
    login = session.expect(/password:\s*\z/i, /Permission denied/i, timeout: 10)
    ScriptProbe.check(login == 1, "SSH password prompt missing (#{session.error || "authentication rejected"})")
    session.write(password, "\n")
    runner = ScriptProbe::Runner.new(session, timeout: 10).ready!
    InteractProbe.prepare(session, echo: !automatic)
    File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.truncate(0) }
    session.log_to(log_path)

    remote_exit = false
    if automatic
      report.merge!(InteractProbe.verify(session, user: user))
    else
      local_terminal = Expect.open($stdin)
      initial_mode = InteractProbe.configuration(local_terminal)
      puts "Logged in as #{user}@#{host}. Enter commands; press Ctrl-] to return to expect."
      puts "Log: #{log_path}"
      # prepare consumed the initial prompt while configuring remote echo.
      $stdout.print(ScriptProbe::PROMPT)
      $stdout.flush
      # This is the actual public API handoff: stdin -> SSH, SSH -> stdout.
      returned = session.interact(input: $stdin, escape: InteractProbe::ESCAPE, output: $stdout)
      ScriptProbe.check(InteractProbe.configuration(local_terminal) == initial_mode,
                        "stdin terminal mode was not restored")
      report[:local_terminal_restored] = true
      report[:checks] += %w[real_stdin_stdout terminal_restored]
      if returned.equal?(session)
        remote_exit = true
        report[:completion] = "remote_exit"
        session.soft_close(timeout: 3)
        ScriptProbe.check(session.closed? && session.exit_code&.zero?,
                          "SSH exited with status #{session.exit_code.inspect}")
        report[:checks] << "remote_eof"
      else
        ScriptProbe.check(returned.is_a?(Expect) && returned.to_io.equal?($stdin), "unexpected interact termination")
        ScriptProbe.check(session.alive?, "remote session ended during interaction")
        report[:completion] = "local_escape"
        report[:checks] += %w[ctrl_bracket_escape remote_alive]
        puts "\nReturned from interact; verifying automated expect resumes..."
        InteractProbe.prepare(session)
        runner.run(
          "expect_after_manual", "printf 'MANUAL_AUTOMATION_RESUMED\\n'",
          expected_status: 0, expected_output: "MANUAL_AUTOMATION_RESUMED\n"
        )
        report[:cases] = runner.results
        report[:checks] << "expect_resume"
      end
    end

    runner.finish! unless remote_exit
    report[:ssh_exit_code] = session.exit_code
    text = ScriptProbe.normalize(File.binread(log_path))
    report[:cases].each do |result|
      output = result.fetch(:output).b
      ScriptProbe.check(text.scan(Regexp.new(Regexp.escape(output), Regexp::NOENCODING)).length == 1,
                        "#{result[:name]}: log output missing or duplicated")
    end
    unless remote_exit
      ScriptProbe.check(text.scan("SESSION_FINAL_TAIL\n").length == 1,
                        "shutdown tail missing or duplicated")
    end
    ScriptProbe.check(!text.include?(InteractProbe::TAIL), "local escape tail leaked to SSH") if automatic
    ScriptProbe.check(!text.include?(password.b), "password detected in log")
    report[:checks] += %w[unique_log_output eof_drain password_absent clean_ssh_exit]
    report[:passed] = true
  end
rescue StandardError => error
  report[:error] = "#{error.class}: #{error.message}".gsub(password, "[REDACTED]")
ensure
  session&.close
  local_terminal&.close
  if File.file?(log_path)
    bytes = File.binread(log_path)
    if bytes.include?(password.b)
      File.binwrite(log_path, bytes.gsub(password.b, "[REDACTED]"))
      report[:passed] = false
      report[:error] = "password detected and removed from log"
    end
    report[:log_bytes] = File.size(log_path)
    report[:log_sha256] = Digest::SHA256.file(log_path).hexdigest
  end
  password.replace("\0" * password.bytesize)
  report[:finished_at] = Time.now.utc.iso8601
  report[:log_path] = log_path
  File.open(report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(report)) }
end

puts "Log: #{log_path}"
puts "Report: #{report_path}"
abort(report[:error]) unless report[:passed]
puts "PASS #{report[:mode]} interact: #{report[:cases].length} command checks, " \
     "#{report[:checks].length} interaction/log checks; SSH exit=0"
