# frozen_string_literal: true

# Opt-in: this script makes a real SSH connection. The default rake test does
# not load it, and no password belongs in fixture files or command arguments.
require "io/console"
require "json"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../support/script_probe"

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

base = File.expand_path(ENV.fetch("EXPECT_LOG_DIR", File.expand_path("../../tmp/ssh-logs", __dir__)))
FileUtils.mkdir_p(base)
directory = Dir.mktmpdir("#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-", base)
log_path = File.join(directory, "session.log")
report_path = File.join(directory, "report.json")
report = { host:, port:, user:, started_at: Time.now.utc.iso8601, passed: false }
runner = nil
session = nil

begin
  Dir.mktmpdir("expect-known-hosts-") do |temporary|
    policy = known_hosts ? "yes" : "accept-new"
    hosts_path = known_hosts || File.join(temporary, "known_hosts")
    args = ["ssh", "-F", "/dev/null", "-tt", "-p", port.to_s,
            "-o", "ConnectTimeout=5", "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
            "-o", "StrictHostKeyChecking=#{policy}", "-o", "UserKnownHostsFile=#{hosts_path}",
            "-l", user, host, "env ENV= PS1=#{Shellwords.escape(ScriptProbe::PROMPT)} /bin/sh -i"]
    # Authentication is completed before opening any log. Parent defaults
    # cannot accidentally turn on debug or console logging for this check.
    session = Expect.spawn(*args, raw_pty: true, log_stdout: false, log_listeners: false,
                                  debug_level: 0, write_timeout: 5)
    authentication = session.expect(/password:\s*\z/i, /Permission denied/i, timeout: 10)
    ScriptProbe.check(authentication.number == 1,
                      "SSH password prompt not received (#{authentication.error || "authentication rejected"})")
    session.write(password, "\n")
    runner = ScriptProbe::Runner.new(session, timeout: 10).ready!
    report.merge!(ScriptProbe.verify_file_session(runner, log_path, user:))
    report[:ssh_exit_code] = session.exit_code
    ScriptProbe.check(!File.binread(log_path).include?(password.b), "password detected in session log")
    report[:checks] << "password_absent"
    report[:passed] = true
  end
rescue StandardError => error
  # Error messages identify the failed check; raw authentication output is
  # deliberately excluded from both the report and the console.
  report[:error] = "#{error.class}: #{error.message}".gsub(password, "[REDACTED]")
  report[:cases] ||= runner&.results || []
ensure
  session&.close
  if File.file?(log_path)
    bytes = File.binread(log_path)
    if bytes.include?(password.b)
      File.binwrite(log_path, bytes.gsub(password.b, "[REDACTED]"))
      report[:passed] = false
      report[:error] = "password detected and removed from log"
    end
    report[:log_sha256] = Digest::SHA256.file(log_path).hexdigest
    report[:log_bytes] = File.size(log_path)
  end
  password.replace("\0" * password.bytesize)
  report[:finished_at] = Time.now.utc.iso8601
  report[:log_path] = log_path
  File.open(report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(report)) }
end

report.fetch(:cases, []).each do |result|
  puts "#{result[:passed] ? "PASS" : "FAIL"} #{result[:name]} " \
       "exit=#{result[:status]} expected=#{result[:expected_status]}"
end
puts "Log: #{log_path}"
puts "Report: #{report_path}"
abort(report[:error]) unless report[:passed]
puts "PASS SSH multi-script execution and #{report[:checks].length} logging checks; SSH exit=0"
