# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tempfile"
require "tmpdir"
require_relative "../lib/expect/pty"
require_relative "support/ssh"

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

options = SSHExample.options
host, user = options.values_at(:host, :user)
password = SSHExample.read_password
log = nil
begin
  Dir.mktmpdir("expect-ssh-") do |dir|
    ssh_args = SSHExample.arguments(options, directory: dir, prompt: PROMPT)

    Expect.spawn(*ssh_args, raw: true, write_timeout: 5) do |ssh|
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
      ssh.transcript = log
      puts "已登录 #{user}@#{host}；日志：#{log.path}"

      COMMANDS.each do |command|
        puts "\n$ #{command}"
        ssh.write_transcript("\n$ #{command}\n")
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
