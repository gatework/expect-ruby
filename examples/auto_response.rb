# frozen_string_literal: true

require "rbconfig"
require_relative "../lib/expect/pty"

# 本地模拟设备：每条配置重复确认、分页、动态问答，再返回独立完成提示。
program = <<~'RUBY'
  STDOUT.sync = true
  puts "device>"
  while (command = STDIN.gets&.strip)
    break if command == "exit"
    2.times do
      print "Apply change? [y/N] "
      abort "confirmation rejected" unless STDIN.gets == "y\n"
    end
    print "--More--"
    abort "wrong page key" unless STDIN.read(1) == " "
    print "Repeat code 42: "
    abort "wrong code" unless STDIN.gets == "42\n"
    puts "applied:#{command}\ndevice>"
  end
RUBY

rules = Expect::Responder.new do |responses|
  responses.on("Apply change? [y/N] ", reply: "y\n", limit: 2)
  responses.on("--More--", reply: " ", limit: 1)
  responses.on(/Repeat code (\d+): /, limit: 1) { |session| session.puts(session.captures.first) }
end.freeze

Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", program, raw: true, write_timeout: 2) do |device|
  abort "device did not start" unless device.expect("device>", timeout: 2).matched?
  ["set vlan 10", "save configuration"].each do |command|
    device.puts(command)
    result = rules.expect(device, "device>", timeout: 2, deadline: Expect.monotonic + 3)
    abort "command failed: #{result.error}" unless result.matched? && result.before.include?("applied:#{command}")

    puts "completed: #{command}"
  end
  device.puts("exit")
  abort "device exit failed" unless device.soft_close(timeout: 2)&.success?
end
