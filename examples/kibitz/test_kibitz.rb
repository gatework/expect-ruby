# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../../test/support/kibitz_probe"

base = File.expand_path(ENV.fetch("EXPECT_LOG_DIR", "../../tmp/kibitz"), __dir__)
FileUtils.mkdir_p(base)
directory = Dir.mktmpdir("#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-", base)
report = { passed: false, cases: [], started_at: Time.now.utc.iso8601 }
begin
  {
    shared_shell: ->(dir) { KibitzProbe.shared_shell(dir) },
    host_escape: ->(dir) { KibitzProbe.direct(dir, ending: :host) },
    guest_escape: ->(dir) { KibitzProbe.direct(dir, ending: :guest) },
    noescape: ->(dir) { KibitzProbe.noescape(dir) },
    process_failure: ->(dir) { KibitzProbe.process_failure(dir) },
    relay_timeout: ->(dir) { KibitzProbe.relay_timeout(dir) }
  }.each do |name, probe|
    path = File.join(directory, name.to_s)
    Dir.mkdir(path, 0o700)
    result = probe.call(path)
    report[:cases] << result.merge(log_path: File.join(path, "session.log"))
    puts "PASS #{name}: #{result[:checks].join(", ")}"
  end
  report[:passed] = true
rescue StandardError => error
  report[:error] = "#{error.class}: #{error.message}"
ensure
  report[:finished_at] = Time.now.utc.iso8601
  path = File.join(directory, "report.json")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(report)) }
  puts "Report: #{path}"
end
abort(report[:error]) unless report[:passed]
