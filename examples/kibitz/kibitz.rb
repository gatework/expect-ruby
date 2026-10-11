# frozen_string_literal: true

require "socket"
require "tmpdir"
require "optparse"
require "shellwords"
require_relative "../../lib/expect/pty"

# 参考 jacoby/expect.pm 的本地双终端示例：两个键盘向同一进程输入，
# 进程输出通过 outputs 同时转发到两个终端。
module Kibitz
  ESCAPE = "\x1d".b.freeze

  # 借用两侧端点建立共享进程或直接互传的输出图，返回停止原因和本地输入尚未转发的尾部。
  # 仅本地键盘注册退出序列；log 记录进程或对端的接收字节，底层 IO 与进程由调用方关闭。
  def self.relay(input:, output:, peer:, shell: nil, escape: ESCAPE, timeout: nil, log: nil)
    Expect.open(input, write_timeout: 5) do |keyboard|
      Expect.open(peer, write_timeout: 5) do |partner|
        keyboard.on_sequence(escape) if escape
        if shell
          keyboard.outputs = [shell]
          partner.outputs = [shell]
          shell.outputs = [output, partner]
          shell.transcript = log if log
        else
          keyboard.outputs = [partner]
          partner.outputs = [output]
          partner.transcript = log if log
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

  # 将 ^A、^] 等单字符控制键表示法转为控制字节；其他非空文本保留为字面退出序列。
  def self.escape(value)
    return (value.getbyte(1) & 31).chr if value.match?(/\A\^[@A-Z\[\\\]\^_]\z/)

    raise OptionParser::InvalidArgument, "escape must not be empty" if value.empty?

    value
  end

  # 解析 host/join 参数，先建连再接管本地终端；退出时恢复终端并关闭本次取得的进程、socket 和日志。
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
    # 两侧终端连接结束后，由 ensure 关闭日志。
    log = File.open(options[:log], File::WRONLY | File::CREAT | File::EXCL, 0o600) if options[:log] # rubocop:disable Style/FileOpen

    if options[:join]
      peer = UNIXSocket.new(options[:join])
    else
      # 使用私有目录中的短 socket 路径，满足 macOS 的 sockaddr_un 长度限制。
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
        # 子进程的终端保留规范输入、回显和 ISIG 信号处理。
        shell = Expect.spawn(*command, write_timeout: 5)
        shell.to_io.winsize = input.winsize
      end
    end
    # 关闭本地回显和规范输入后再发出就绪提示。
    # 用户或 PTY 驱动可能在提示出现后立即发送输入。
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
