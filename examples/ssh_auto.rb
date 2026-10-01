# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tempfile"
require "tmpdir"
require_relative "../lib/expect/pty"

# 在这里按顺序填写要执行的 macOS / POSIX shell 命令。
COMMANDS = ["id", "uname -srm", "sw_vers", "df -h /", "uptime"].freeze
PROMPT = "MACOS> "

if ARGV.delete("--help")
  puts "用法：ruby examples/ssh_auto.rb [--no-interact]"
  puts "自动 SSH 登录，执行 COMMANDS 后进入 interact；--no-interact 执行后退出。"
  puts "环境变量：SSH_HOST、SSH_USER、SSH_PORT、SSH_KNOWN_HOSTS、EXPECT_PASSWORD、EXPECT_LOG_DIR。"
  exit
end
interactive = !ARGV.delete("--no-interact")
abort "未知参数：#{ARGV.join(" ")}" unless ARGV.empty?
abort "interact 需要终端；批量执行请加 --no-interact" if interactive && !$stdin.tty?

host = ENV.fetch("SSH_HOST", "127.0.0.1")
user = ENV.fetch("SSH_USER", ENV.fetch("USER", "crate"))
port = Integer(ENV.fetch("SSH_PORT", "22"), 10)
abort "SSH_PORT 应为 1..65535" unless (1..65_535).cover?(port)
abort "SSH_HOST / SSH_USER 格式无效" if [host, user].any? do |value|
  value.empty? || value.start_with?("-") || value.match?(/[\s\x00]/)
end
known_hosts = ENV.fetch("SSH_KNOWN_HOSTS", nil)
abort "连接其他主机时请设置 SSH_KNOWN_HOSTS" unless known_hosts || %w[127.0.0.1 ::1 localhost].include?(host)

password = ENV.delete("EXPECT_PASSWORD")&.dup
log = nil
begin
  unless password
    $stderr.print("SSH password: ")
    password = ($stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets)&.chomp
    $stderr.puts
  end
  abort "请输入单行密码" if password.nil? || password.empty? || password.match?(/[\r\n\x00]/)

  Dir.mktmpdir("expect-ssh-") do |dir|
    ssh_args = ["ssh", "-F", "/dev/null", "-tt", "-p", port.to_s,
                "-o", "ConnectTimeout=5", "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
                "-o", "StrictHostKeyChecking=#{known_hosts ? "yes" : "accept-new"}",
                "-o", "UserKnownHostsFile=#{known_hosts || File.join(dir, "known_hosts")}",
                "-l", user, host, "env ENV= PS1=#{Shellwords.escape(PROMPT)} /bin/sh -i"]

    Expect.spawn(*ssh_args, raw_pty: true, log_stdout: false, write_timeout: 5) do |ssh|
      # 登录成功后才开启日志，密码不写入文件。
      ssh.expect(/password:\s*\z/i, timeout: 10).matched? or abort "未收到密码提示：#{ssh.error}"
      ssh.write(password, "\n")
      ssh.expect(PROMPT, timeout: 10).matched? or abort "SSH 登录失败：#{ssh.error}"
      password.replace("\0" * password.bytesize)
      ssh.write("stty sane -echo; set +o emacs; set +o vi\n")
      ssh.expect(PROMPT, timeout: 5).matched? or abort "终端初始化失败：#{ssh.error}"

      log_dir = ENV.fetch("EXPECT_LOG_DIR", File.expand_path("../tmp/ssh-auto", __dir__))
      FileUtils.mkdir_p(log_dir)
      log = Tempfile.create(["session-", ".log"], log_dir) # 0600，退出后保留
      ssh.log_to(log)
      puts "已登录 #{user}@#{host}；日志：#{log.path}"

      COMMANDS.each do |command|
        puts "\n$ #{command}"
        ssh.write_log("\n$ #{command}\n")
        token = SecureRandom.hex(8)
        # 远端拼接结束标记并带回退出码，避免把命令回显当成执行结果。
        ssh.write("#{command}; printf '\\n__DONE_%s:%s\\n' '#{token}' \"$?\"\n")
        ssh.expect(/\r?\n__DONE_#{token}:(\d+)\r?\n#{Regexp.escape(PROMPT)}/,
                   timeout: 30).matched? or abort "命令未完成：#{ssh.error}"
        print ssh.before.gsub("\r\n", "\n")
        abort "命令失败（退出码 #{ssh.captures.first}）：#{command}" unless ssh.captures.first == "0"
      end

      if interactive
        ssh.write("stty echo\n")
        ssh.expect(PROMPT, timeout: 5).matched? or abort "无法进入交互：#{ssh.error}"
        puts "\n检查完成，进入 interact。输入 exit 或按 Ctrl-] 结束。"
        $stdout.print(PROMPT)
        $stdout.flush
        next unless ssh.interact(input: $stdin, escape: "\x1d", output: $stdout).equal?(ssh)
      else
        ssh.write("exit\n")
      end
      ssh.soft_close(timeout: 3)
      abort "SSH 退出异常：#{ssh.exit_code.inspect}" unless ssh.exit_code&.zero?
    end
  end
ensure
  log&.close
  password&.replace("\0" * password.bytesize)
end
