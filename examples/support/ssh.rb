# frozen_string_literal: true

require "etc"
require "io/console"
require "shellwords"

# 统一 SSH 示例的输入校验；此处不建立连接。
module SSHExample
  def self.options(environment = ENV)
    host = environment.fetch("SSH_HOST", "127.0.0.1")
    user = environment.fetch("SSH_USER") { environment.fetch("USER") { Etc.getpwuid.name } }
    port = Integer(environment.fetch("SSH_PORT", "22"), 10)
    unless [host, user].none? { |value| value.empty? || value.start_with?("-") || value.match?(/[\s\x00]/) }
      raise ArgumentError, "invalid SSH host or user"
    end
    raise ArgumentError, "SSH_PORT must be between 1 and 65535" unless (1..65_535).cover?(port)

    known_hosts = environment["SSH_KNOWN_HOSTS"]
    raise ArgumentError, "SSH_KNOWN_HOSTS must not be empty" if known_hosts == ""
    unless known_hosts || %w[127.0.0.1 ::1 localhost].include?(host)
      raise ArgumentError, "SSH_KNOWN_HOSTS is required for remote hosts"
    end

    { host:, user:, port:, known_hosts: }
  end

  def self.read_password(environment: ENV, input: $stdin, output: $stderr)
    password = environment.delete("EXPECT_PASSWORD")&.dup
    unless password
      output.print("SSH password: ")
      password = (input.tty? ? input.noecho(&:gets) : input.gets)&.chomp
      output.puts
    end
    unless password && !password.empty? && !password.match?(/[\r\n\x00]/)
      raise ArgumentError, "a single-line password is required"
    end

    password
  end

  def self.arguments(options, directory:, prompt:)
    host, user, port, known_hosts = options.values_at(:host, :user, :port, :known_hosts)
    # OpenSSH 会再次解析 -o 参数；按 ssh_config 语法引用单个文件路径。
    # 转义规则与 shell 不同：OpenSSH 会原样保留 shell 风格的 \#。
    hosts_path = known_hosts || File.join(directory, "known_hosts")
    if hosts_path.include?("${")
      raise ArgumentError, "known_hosts path must not contain ${ expressions expanded by OpenSSH"
    end

    # 引号不阻止百分号展开；用 %% 表示一个字面百分号。
    hosts_path = hosts_path.gsub("%", "%%")
    quoted_hosts_path = %("#{hosts_path.gsub(/[\\"]/) { |character| "\\#{character}" }}")
    ["ssh", "-F", "/dev/null", "-tt", "-p", port.to_s,
     "-o", "ConnectTimeout=5", "-o", "NumberOfPasswordPrompts=1",
     "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
     "-o", "StrictHostKeyChecking=#{known_hosts ? "yes" : "accept-new"}",
     "-o", "UserKnownHostsFile=#{quoted_hosts_path}",
     "-l", user, host, "env ENV= PS1=#{Shellwords.escape(prompt)} /bin/sh -i"]
  end
end
