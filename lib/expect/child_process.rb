# frozen_string_literal: true

module Expect
  # 启动与监管直属子进程；资源身份只保存在传入的 ResourceOwner，不持有 Session。
  # @api private
  class ChildProcess
    def initialize(resources)
      @resources = resources
    end

    def pid = @resources.pid

    # 状态未知或 EINTR 时不伪造退出事实；等待循环继续使用原期限。
    def status
      @resources.reap
    rescue Errno::EINTR
      @resources.status
    end

    # 管道、fork 与 PID 登记维持原所有权窗口；可由 Session 提供子进程启动钩子。
    def spawn(command, env:, chdir:, shell:)
      from_child = to_parent = nil
      Cleanup.always(-> { ResourceOwner.close_handles(from_child, to_parent) }) do
        Thread.handle_interrupt(Object => :never) { from_child, to_parent = IO.pipe }
        to_parent.close_on_exec = true
        child = Thread.handle_interrupt(Object => :never) do
          @resources.pid = fork do
            Thread.handle_interrupt(Object => :immediate) do
              if block_given?
                yield from_child, to_parent
              else
                exec_child(command, env:, chdir:, from_child:, to_parent:, shell:)
              end
            end
          end
        end
        to_parent.close
        @resources.slave.close
        failure = from_child.read
        raise_spawn_error(failure) unless failure.empty?
        child
      end
    end

    # 每阶段只计算一次期限；回收或信号被中断后仍沿用剩余预算，零预算也先做一次尝试。
    def wait(period, signal: nil)
      deadline = period && (Expect.monotonic + period)
      interval = 0.001
      loop do
        state = status
        return state if state || !pid || @resources.owner != Process.pid

        begin
          self.signal(signal) if signal
          signal = nil
        rescue Errno::EINTR
          # 下轮先回收再重试信号，避免在无限等待或持续中断时忙等。
          nil
        end
        # ESRCH 后可能已完成回收；即使预算耗尽，也要返回刚获得的状态。
        return status unless pid

        remaining = deadline && (deadline - Expect.monotonic)
        return nil if remaining && remaining <= 0

        pause = remaining ? [interval, remaining].min : interval
        block_given? ? yield(pause) : sleep(pause)
        interval = [interval * 2, 0.01].min
      end
    end

    # 仅由资源创建者向仍未回收的子进程发送信号；若进程刚好退出，则尝试回收。
    def signal(signal)
      return unless pid && @resources.owner == Process.pid

      Process.kill(signal, pid)
    rescue Errno::ESRCH
      @resources.reap
    end

    # 子进程独占控制终端；成功 exec 关闭错误管道，失败时回传后立即退出。
    def exec_child(command, env:, chdir:, from_child:, to_parent:, shell:)
      from_child.close
      Process.setsid
      # 创建独立进程会话后重新打开 slave，使它成为子进程的控制终端。
      File.open(@resources.slave.path, File::RDWR) do |terminal|
        # 重定向操作系统的标准描述符；即使宿主替换过 Ruby 标准流，也能正确连接子进程。
        # rubocop:disable Style/GlobalStdStream
        STDIN.reopen(terminal)
        STDOUT.reopen(terminal)
        STDERR.reopen(terminal)
        # rubocop:enable Style/GlobalStdStream
      end
      @resources.close_handles
      Dir.chdir(chdir) if chdir
      executable, *arguments = shell ? ["/bin/sh", "-c", command.first] : command
      exec(env, [executable, executable], *arguments, close_others: true)
    rescue Exception => error # rubocop:disable Lint/RescueException -- 子进程回传启动异常后立即退出。
      begin
        message = error.message.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        to_parent.write(JSON.generate(class: error.class.name, message:,
                                      errno: error.is_a?(SystemCallError) ? error.errno : nil))
      ensure
        exit! 127
      end
    end

    # 错误管道只传递标量；系统错误从 errno 恢复，不动态加载异常类。
    def raise_spawn_error(payload)
      failure = JSON.parse(payload)
      errno = failure.fetch("errno")
      message = "#{failure.fetch("class")}: #{failure.fetch("message")}"
      cause = errno ? SystemCallError.new(failure.fetch("message"), errno) : ChildFailure.new(message)
      raise SpawnError.new(message, errno:), cause:
    rescue JSON::ParserError, KeyError => error
      raise SpawnError.new("invalid child startup failure"), cause: error
    end
  end
  private_constant :ChildProcess
end
