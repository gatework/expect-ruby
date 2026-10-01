# frozen_string_literal: true

# Optional real SSH integration check. Password input is hidden and never logged.
require "io/console"
require "tmpdir"
require "securerandom"
require_relative "../lib/expect/pty"

host = ENV.fetch("SSH_HOST", "127.0.0.1")
user = ENV.fetch("SSH_USER", ENV.fetch("USER", "crate"))
abort "invalid SSH host or user" if [host, user].any? do |value|
  value.empty? || value.start_with?("-") || value.match?(/[\s\x00]/)
end
password = ENV.delete("EXPECT_PASSWORD")&.dup
unless password
  $stderr.print("SSH password: ")
  password = $stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets
  $stderr.puts
  password = password&.chomp
end
abort "password is required" if password.nil? || password.empty?

begin
  Dir.mktmpdir("expect-ssh-") do |dir|
    # Isolated known_hosts keeps this example independent of user SSH settings.
    # For non-loopback hosts, use an existing trusted known_hosts file.
    known_hosts = ENV.fetch("SSH_KNOWN_HOSTS", nil)
    abort "SSH_KNOWN_HOSTS is required for remote hosts" unless known_hosts || %w[127.0.0.1 ::1
                                                                                  localhost].include?(host)
    policy = known_hosts ? "yes" : "accept-new"
    known_hosts ||= File.join(dir, "known_hosts")
    arguments = ["ssh", "-F", "/dev/null", "-tt", "-o", "ConnectTimeout=5",
                 "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
                 "-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=#{policy}",
                 "-o", "UserKnownHostsFile=#{known_hosts}", "-l", user, host,
                 "env PS1='EXPECT_SHELL> ' /bin/sh -i"]
    Expect.spawn(*arguments, log_stdout: false, raw_pty: true) do |session|
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
