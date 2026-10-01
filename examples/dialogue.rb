# frozen_string_literal: true

require_relative "../lib/expect/pty"
require "rbconfig"

program = <<~'RUBY'
  STDOUT.sync = true
  print "Name: "
  name = STDIN.gets.strip
  print "Code: "
  code = STDIN.gets.strip
  puts "Hello #{name}, code=#{code}"
RUBY

Expect.spawn(RbConfig.ruby, "-e", program, raw: true) do |session|
  result = session.expect(timeout: 3) do
    on("Name: ") do |connection|
      connection.puts("Ruby")
      Expect.continue
    end
    on("Code: ") do |connection|
      connection.puts("1234")
      Expect.continue
    end
    on(/Hello (\w+), code=(\d+)/)
  end
  abort(result.error.to_s) unless result.matched?
  puts session.match
  session.soft_close(timeout: 1)
end
