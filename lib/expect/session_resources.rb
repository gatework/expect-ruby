# frozen_string_literal: true

class Expect
  # 独立保存句柄、PID 和日志所有权，让终结器无需直接捕获会话即可清理遗弃资源。
  # IO 是否关闭与子进程是否退出分别记录；不能仅凭句柄状态清空 PID 或伪造退出状态。
  # @api private
  class SessionResources
    # owned_log 只保存库打开的文件；借用的 IO/日志回调留在会话中，不能成为终结器的引用根。
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
    # 常规关闭错误延后到所有句柄尝试完再抛出，失败句柄仍留在账本内供下一次关闭重试。
    def close_handles
      self.class.close_handles(reader, writer, slave) if own
    end

    # 账本尚未建立时也能释放局部 IO；不依赖完整会话，也不调用无效参数上的用户方法。
    def self.close_handles(*handles)
      # 初始化校验失败时可能含无效参数，只关闭真实 IO；PTY 读写端也需要去重。
      failure = nil
      handles.grep(IO).uniq(&:object_id).each do |io|
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
      # 无法获取别人已取走的 Process::Status，保留未知状态而不是推断成功或失败。
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
          finalize_child
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    # 构造只持有资源对象的终结回调，避免闭包中的 self 绑定到会话而妨碍回收。
    def self.finalizer(resources)
      proc { resources.finalize }
    end

    private

    # GC 只做一次非阻塞回收和最多两次信号尝试；失败也把等待交给 detach，不运行用户回调。
    def finalize_child
      begin
        reap
      rescue Errno::EINTR
        # GC 不等待下轮轮询，仍对本进程拥有的子进程执行后续有限清理。
        nil
      end
      return unless pid && owner == Process.pid

      begin
        2.times do
          break unless pid && owner == Process.pid

          Process.kill("KILL", pid)
          break
        rescue Errno::EINTR
          next
        rescue Errno::ESRCH
          break
        end
      ensure
        if pid && owner == Process.pid
          Process.detach(pid)
          @pid = nil
        end
      end
    rescue Errno::ECHILD
      @pid = nil
    end
  end
end
