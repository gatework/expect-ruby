# frozen_string_literal: true

class Expect
  # 独立保存句柄、PID 和日志所有权，让终结器无需直接捕获会话即可清理遗弃资源。
  class SessionResources
    attr_accessor :pid, :status, :owned_log
    attr_reader :reader, :writer, :slave, :owner, :own

    # 记录创建资源的进程；fork 后的副本不能向父进程拥有的子进程发信号。
    def initialize(reader, writer:, slave: nil, own: false)
      @reader = reader
      @writer = writer
      @slave = slave
      @own = own
      @owner = Process.pid
    end

    # 只关闭由本库拥有的 IO；借用的 reader、writer 由调用方管理。
    def close_handles
      return unless own

      # 初始化校验失败时可能含无效参数，只关闭真实 IO；PTY 读写端也需要去重。
      failure = nil
      [reader, writer, slave].grep(IO).uniq.each do |io|
        io.close unless io.closed?
      rescue IOError, SystemCallError => error
        failure ||= error
      end
      raise failure if failure
    end

    # 非阻塞回收直属子进程，缓存 Process::Status，成功后清空 PID 以支持重复查询。
    def reap
      return status unless pid && owner == Process.pid

      if (reaped = Process.waitpid2(pid, Process::WNOHANG))
        @status = reaped.last
        @pid = nil
      end
      status
    rescue Errno::ECHILD
      # 子进程可能已被调用方或其他线程回收，不再保留可能被系统复用的 PID。
      @pid = nil
      status
    end

    # GC 兜底关闭所属句柄和日志，并强制终止尚存活的子进程；不执行软关闭等待。
    def finalize
      return unless owner == Process.pid

      begin
        close_handles
      ensure
        begin
          owned_log.close if owned_log && !owned_log.closed?
        ensure
          # 每个阶段独立收尾；句柄或日志关闭失败不能跳过进程回收。
          reap
          if pid
            begin
              Process.kill("KILL", pid)
            rescue Errno::ESRCH
              # 子进程可能刚好退出，仍需尝试 wait，不能留下僵尸进程。
              nil
            end
            # 将最终 wait 交给后台回收线程，避免在 GC 终结器中阻塞等待。
            Process.detach(pid)
            @pid = nil
          end
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    # 构造只持有资源对象的终结回调，避免闭包中的 self 绑定到会话而妨碍回收。
    def self.finalizer(resources)
      proc { resources.finalize }
    end
  end
end
