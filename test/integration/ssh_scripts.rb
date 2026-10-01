# frozen_string_literal: true

# Opt-in: this script makes a real SSH connection. The default rake test does
# not load it, and no password belongs in fixture files or command arguments.
require "io/console"
require "json"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../support/script_probe"
require_relative "../../examples/support/ssh"

options = SSHExample.options
host, user, port = options.values_at(:host, :user, :port)
password = SSHExample.read_password

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
    args = SSHExample.arguments(options, directory: temporary, prompt: ScriptProbe::PROMPT)
    session = Expect.spawn(*args, raw: true, write_timeout: 5)
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
