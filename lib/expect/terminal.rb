# frozen_string_literal: true

require "shellwords"

# 会话终端的模式和窗口尺寸接口；人工接管期间的临时恢复由 interaction.rb 负责。
class Expect
  # @api private
  module Terminal
    # 查询可恢复的终端模式字符串，或通过系统 stty 设置模式；参数按数组传递，不经 shell。
    # 辅助进程与管道独立记账，不能覆盖主会话 PID；失败时保留原异常并有界回收。
    def stty(*modes)
      return "" unless tty?

      modes = modes.flat_map { |mode| Shellwords.split(mode.to_s) }
      modes = ["-g"] if modes.empty?
      reader = sink = resources = nil
      Cleanup.always(-> { cleanup_stty(resources, reader, sink) }) do
        reader, sink = IO.pipe
        resources = SessionResources.new(reader, writer: sink, own: true)
        resources.pid = Process.spawn("stty", *modes, in: to_io, out: sink, err: sink)
        sink.close
        output = reader.read
        status = wait_stty(resources.pid)
        resources.pid = nil
        raise IOError, "stty failed: #{output.strip}" unless status.success?

        output.strip
      rescue Errno::ENOENT
        raise IOError, "stty executable not found in PATH; install the system terminal utilities"
      end
    end

    # 读取终端的 [行数, 列数]；底层并非终端或句柄已关闭时保留原生 IO 异常。
    def winsize = to_io.winsize

    # 更新终端尺寸，由内核通知前台进程。
    def winsize=(size)
      to_io.winsize = size
    end

    private

    # 正常路径阻塞取得真实状态，不额外轮询或固定等待；EINTR 不重新执行 stty。
    def wait_stty(pid)
      Process.waitpid2(pid).last
    rescue Errno::EINTR
      retry
    end

    # 即使账本初始化被中断，局部变量中的管道仍须关闭；单端失败不跳过其他清理。
    # 无主异常时由调用方传播首个常规清理错误。
    def cleanup_stty(resources, reader, sink)
      failure = nil
      [reader, sink].compact.each do |io|
        io.close unless io.closed?
      rescue IOError, SystemCallError => error
        failure ||= error
      end
      begin
        reap_stty(resources) if resources
      rescue IOError, SystemCallError => error
        failure ||= error
      end
      raise failure if failure
    end

    # 每阶段共享固定的 50ms 单调时钟预算：自然退出、TERM、KILL；中断不续期。
    # 仍无法同步回收或系统调用失败时交给 detach 的后台 wait，不伪造退出状态。
    def reap_stty(resources)
      return unless resources.owner == Process.pid

      [nil, "TERM", "KILL"].each do |signal|
        deadline = Expect.monotonic + 0.05
        loop do
          begin
            resources.reap
            return resources.status unless resources.pid && resources.owner == Process.pid

            if signal
              begin
                Process.kill(signal, resources.pid)
              rescue Errno::ESRCH
                # 退出可发生在非阻塞 wait 与信号之间，仍需继续 wait。
                nil
              end
              signal = nil
            end
          rescue Errno::EINTR
            # 重试沿用本阶段期限，连续 EINTR 也必须交还控制权。
            nil
          end
          remaining = deadline - Expect.monotonic
          break unless remaining.positive?

          sleep [remaining, 0.005].min
        end
      end
    ensure
      Process.detach(resources.pid) if resources.pid && resources.owner == Process.pid
    end
  end
end
