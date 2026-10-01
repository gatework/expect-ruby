# frozen_string_literal: true

require "socket"
require "tmpdir"
require "optparse"
require "shellwords"
require_relative "../../lib/expect/pty"

# Local counterpart of jacoby/expect.pm examples/kibitz: both keyboards feed
# one process, whose output is broadcast to both terminals using listeners.
module Kibitz
  ESCAPE = "\x1d".b.freeze

  def self.relay(input:, output:, peer:, shell: nil, escape: ESCAPE, timeout: nil, log: nil)
    Expect.open(input, log_stdout: false, write_timeout: 5) do |keyboard|
      Expect.open(peer, log_stdout: false, write_timeout: 5) do |partner|
        keyboard.on_sequence(escape) if escape
        if shell
          keyboard.listeners = [shell]
          partner.listeners = [shell]
          shell.listeners = [output, partner]
          shell.log_stdout = false
          shell.log_output = log if log
          # Keep canonical input, echo and ISIG on the process's own terminal.
          shell.raw_terminal = false
        else
          keyboard.listeners = [partner]
          partner.listeners = [output]
          partner.log_output = log if log
        end
        stopped = Expect.interconnect(*[keyboard, partner, shell].compact, timeout:)
        reason = if stopped.nil?
                   :timeout
                 elsif stopped.equal?(keyboard)
                   :local
                 elsif stopped.equal?(partner)
                   :peer
                 else
                   :process
                 end
        { reason:, tail: keyboard.buffer }
      end
    end
  end

  def self.escape(value)
    return (value.getbyte(1) & 31).chr if value.match?(/\A\^[@A-Z\[\\\]\^_]\z/)

    raise OptionParser::InvalidArgument, "escape must not be empty" if value.empty?

    value
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- CLI 建连、终端接管和 ensure 清理共享一次生命周期。
  def self.run(argv, input: $stdin, output: $stdout)
    options = { escape: ESCAPE }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby examples/kibitz/kibitz.rb [options] [-- program args...]"
      opts.on("--join SOCKET", "Join the local session printed by its host") { |value| options[:join] = value }
      opts.on("--noproc", "Exchange input directly, with no shared process or local echo") { options[:noproc] = true }
      opts.on("--escape TEXT", "Local exit sequence (default ^]; caret notation accepted)") do |value|
        options[:escape] = escape(value)
      end
      opts.on("--noescape", "Forward all keys; end by exiting the shared process") { options[:escape] = nil }
      opts.on("--timeout SECONDS", Float, "Limit connection wait and then relay duration") do |value|
        options[:timeout] = value
      end
      opts.on("--log FILE", "Create a new received-output log (0600)") { |value| options[:log] = value }
      opts.on("-h", "--help") do
        output.puts(opts)
        return 0
      end
    end
    parser.order!(argv)
    raise OptionParser::InvalidArgument, "a terminal is required" unless input.tty?
    if options[:timeout] && (!options[:timeout].finite? || options[:timeout] <= 0)
      raise OptionParser::InvalidArgument,
            "timeout must be positive and finite"
    end
    if options[:join] && (options[:noproc] || !argv.empty?)
      raise OptionParser::InvalidArgument,
            "--join cannot start a program or use --noproc"
    end
    raise OptionParser::InvalidArgument, "--noproc cannot start a program" if options[:noproc] && !argv.empty?

    output.sync = true
    # The ensure below closes the log after both terminal connections end.
    log = File.open(options[:log], File::WRONLY | File::CREAT | File::EXCL, 0o600) if options[:log] # rubocop:disable Style/FileOpen

    if options[:join]
      peer = UNIXSocket.new(options[:join])
    else
      # A short, private socket path works with macOS's sockaddr_un limit.
      directory = Dir.mktmpdir("expect-kibitz-", "/tmp")
      socket_path = File.join(directory, "peer.sock")
      server = UNIXServer.new(socket_path)
      File.chmod(0o600, socket_path)
      output.puts("Join from another terminal on this machine:")
      output.puts(Shellwords.join([RbConfig.ruby, File.expand_path(__FILE__), "--join", socket_path]))
      raise IOError, "timed out waiting for partner" unless server.wait_readable(options[:timeout])

      peer = server.accept
      server.close
      File.unlink(socket_path)
      unless options[:noproc]
        command = argv.empty? ? [ENV.fetch("SHELL", "/bin/sh")] : argv
        shell = Expect.spawn(*command, log_stdout: false, raw_terminal: false, write_timeout: 5)
        shell.winsize = input.winsize
      end
    end
    # Announce readiness only after local echo/canonical input are disabled.
    # A fast typist (or PTY driver) may send bytes immediately after the banner.
    result = input.raw do
      hint = options[:escape] ? "Escape #{options[:escape].inspect} ends this session." : "Escape disabled."
      output.write("Kibitz connected. #{hint}\r\n")
      relay(input:, output:, peer:, shell:,
            escape: options[:escape], timeout: options[:timeout], log:)
    end
    if result[:reason] == :process
      shell.soft_close(timeout: 2)
      status = shell.exit_code || 1
    else
      status = result[:reason] == :timeout ? 1 : 0
    end
    output.puts("\nKibitz ended (#{result[:reason]}).")
    status
  rescue OptionParser::ParseError, IOError, SystemCallError, Expect::SpawnError => error
    warn "kibitz: #{error.message}"
    1
  ensure
    shell&.close
    peer&.close
    server&.close unless server&.closed?
    log&.close
    File.unlink(socket_path) if socket_path && File.socket?(socket_path)
    Dir.rmdir(directory) if directory && Dir.exist?(directory)
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end

exit Kibitz.run(ARGV) if $PROGRAM_NAME == __FILE__
