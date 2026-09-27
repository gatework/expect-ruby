# frozen_string_literal: true

# 管理日志目标、监听器及同步输出；资源所有权仍由会话的 SessionResources 统一保存。
class Expect
  # 读取当前日志目标，可能为库打开的文件、借用的 IO、回调或 nil。
  attr_reader :log_output

  # 替换借用的日志目标或停止日志；先校验新目标，失败时保留旧目标。
  def log_output=(target)
    unless target.nil? || target.respond_to?(:write) || target.respond_to?(:call)
      raise ArgumentError, "log output must support write or call, or be nil"
    end

    replace_log(target)
  end

  # 打开追加/覆盖日志文件，或注册接收字节的日志块；同一次只能指定一种目标。
  def log_to(target = nil, mode: "a", &block)
    raise ArgumentError, "provide a log target or a block, not both" if block && target

    target = block if block
    if target.respond_to?(:to_path) || target.is_a?(String)
      raise ArgumentError, "log mode must be a or w" unless %w[a w].include?(mode)

      # 库打开的文件由 SessionResources 持有，替换日志或关闭会话时释放；外部 IO 只借用。
      replace_log(File.open(target, "#{mode}b", 0o600), owned: true)
    else
      raise ArgumentError, "provide a log target or a block" unless target

      self.log_output = target
    end
  end

  # 向当前日志目标补写内容，支持 IO 和回调，不发送给子进程或监听器。
  def write_log(*objects)
    target = log_output
    return unless target

    data = objects.map { |object| object.to_s.b }.join
    target.respond_to?(:call) ? target.call(data) : emit(target, data)
  end

  # 返回监听器列表副本，避免外部原地修改转发关系。
  def listeners = @listeners.dup

  # 校验所有监听器均可写后一次性替换列表，外部数组后续修改不会影响会话。
  def listeners=(outputs)
    outputs = Array(outputs)
    raise ArgumentError, "listeners must support write" unless outputs.all? { |output| output.respond_to?(:write) }

    @listeners = outputs.dup
  end

  private

  # 按各自开关将接收字节转发到 stdout 和监听器，不重复写日志。
  def propagate(data)
    emit($stdout, data) if log_stdout?
    @listeners.each { |listener| emit(listener, data) } if log_listeners?
  end

  # 向目标写入并在支持时立即 flush，使日志和终端输出及时可见。
  def emit(target, data)
    offset = 0
    while offset < data.bytesize
      count = target.write(data.byteslice(offset..))
      unless count.is_a?(Integer) && count.positive? && count <= data.bytesize - offset
        raise IOError, "write must return the number of accepted bytes"
      end

      offset += count
    end
    target.flush if target.respond_to?(:flush)
  end

  # 按诊断级别向 stderr 输出会话标识和消息。
  def trace(message, level: 1)
    warn("#{inspect}: #{message}") if debug_level >= level
  end

  # 交接日志目标和所有权，只关闭库拥有的旧文件；失败时释放新打开的文件。
  def replace_log(target, owned: false)
    previous = log_output
    # 重复赋值同一目标时保留原所有权，防止将库打开的文件误变成借用资源。
    return target if previous.equal?(target)

    previous.close if @resources.owned_log && previous && !previous.closed?
    # 终结器只持有所属文件；借用回调可能捕获会话，不能让它经资源对象成为 GC 根。
    @resources.owned_log = owned ? target : nil
    @log_output = target
    target
  rescue Exception # rubocop:disable Lint/RescueException -- 替换失败时仍释放刚打开的文件。
    target.close if owned && target && !target.closed?
    raise
  end
end
