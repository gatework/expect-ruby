# frozen_string_literal: true

# Optional real SSH integration check. Password input is hidden and never logged.
require "io/console"
require "tmpdir"
require "securerandom"
require_relative "../lib/expect/pty"
require_relative "support/ssh"

options = SSHExample.options
host, user = options.values_at(:host, :user)
password = SSHExample.read_password

begin
  Dir.mktmpdir("expect-ssh-") do |dir|
    arguments = SSHExample.arguments(options, directory: dir, prompt: "EXPECT_SHELL> ")
    Expect.spawn(*arguments, raw: true) do |session|
      prompt = session.expect(/password:\s*\z/i, /Permission denied/i, timeout: 10).number
      abort "SSH password prompt not received (#{session.error || "authentication rejected"})" unless prompt == 1
      session.write(password, "\n")
      password.replace("\0" * password.bytesize)

      # Start a command after authentication. The marker is assembled remotely
      # from two quoted arguments, so terminal command echo cannot satisfy it.
      login = session.expect("EXPECT_SHELL> ", /Permission denied/i, timeout: 10).number
      abort "SSH login failed (#{session.error || "authentication rejected"})" unless login == 1
      token = SecureRandom.hex(12)
      session.write("printf '\\n%s%s\\n' 'EXPECT_OK_' '#{token}'; id -un; tty\n")
      marker = session.expect(/EXPECT_OK_#{Regexp.escape(token)}\r?\n/, timeout: 10)
      abort "remote command did not run (#{session.error})" unless marker.matched?
      identity = session.expect(%r{([^\r\n]+)\r?\n(/dev/[^\r\n]+)\r?\n}, timeout: 5)
      abort "remote identity/TTY response missing" unless identity.matched?
      abort "unexpected SSH user" unless session.captures.first == user.b
      puts "SSH password login verified: #{user}@#{host}"
      puts "Remote identity: #{session.captures.first}; TTY: #{session.captures.last}"
      session.write("exit\n")
      session.soft_close(timeout: 5)
      abort "SSH exit status #{session.exit_code.inspect}" unless session.exit_code&.zero?
      puts "SSH exited cleanly (0)"
    end
  end
ensure
  password&.replace("\0" * password.bytesize)
end
