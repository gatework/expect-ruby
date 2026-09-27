# frozen_string_literal: true

require_relative "redactor"

# 管理日志目标、监听器及同步输出；资源所有权仍由会话的 SessionResources 统一保存。
# 接收日志、诊断和协议转发是三条独立通道；脱敏只改变前两条，不改变匹配或转发字节。
class Expect
  # 读取当前日志目标，可能为库打开的文件、借用的 IO、回调或 nil。
  attr_reader :log_output, :diagnostic_output

  # 诊断目标仅借用；nil 沿用 stderr，Logger 使用 info/debug，回调接收冻结的事件 Hash。
  # 先校验再冲刷旧流；校验或冲刷失败时保留旧目标，避免把暂存尾部交给错误的接收方。
  def diagnostic_output=(target)
    unless target.nil? || (target.respond_to?(:info) && target.respond_to?(:debug)) ||
           target.respond_to?(:write) || target.respond_to?(:call)
      raise ArgumentError, "diagnostic output must support info/debug, write or call, or be nil"
    end
    return if @diagnostic_output.equal?(target)

    flush_diagnostics
    @diagnostic_output = target
  end

  # 秘密仅作用于本会话的日志和诊断，不改写匹配、stdout 显示或 listeners 的协议字节。
  # 先校验全部值再发布；注册是追加操作，应在首次通信前完成，不能追溯已交付的日志。
  def redact(*secrets)
    unless secrets.any? && secrets.all? { |secret| secret.is_a?(String) && !secret.empty? }
      raise ArgumentError, "secrets must be nonempty Strings"
    end

    @secrets = ((@secrets || []) + secrets.map { |secret| secret.b.freeze }).uniq.freeze
    @log_redactor.patterns = @secrets if @log_redactor
    @diagnostic_redactors&.each_value { |redactor| redactor.patterns = @secrets }
    self
  end

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

      # 先交付旧过滤尾部，再允许新路径截断；同一文件不能在截断后被旧句柄写回。
      flush_log
      # 库打开的文件由 SessionResources 持有，替换日志或关闭会话时释放；外部 IO 只借用。
      replace_log(File.open(target, "#{mode}b", 0o600), owned: true)
    else
      raise ArgumentError, "provide a log target or a block" unless target

      self.log_output = target
    end
  end

  # 向当前日志目标补写内容，支持 IO 和回调，不发送给子进程或监听器。
  # 启用脱敏后可能暂存末尾字节，因此一次调用不保证触发一次日志写入或回调。
  def write_log(*objects)
    target = log_output
    return unless target

    data = objects.map { |object| object.to_s.b }.join
    if @secrets
      @log_redactor ||= Redactor.new(@secrets)
      data = @log_redactor.append(data)
      return if data.empty?
    end
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
  # 这里遵循同步写入协议，不受 Matcher 的 IO 等待期限中断；慢目标转接应使用 Relay。
  # 短写只推进已确认的字节数；目标抛错时不猜测它是否已经产生副作用。
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

  # 字节诊断在 inspect 转义之前过滤；缓冲快照可能只含秘密中间片段，启用脱敏时不展开。
  def trace_data(event, data, level:)
    if @secrets
      return trace("buffer [FILTERED]", level: level, event: event) if event == :buffer

      @diagnostic_redactors ||= {}
      redactor = (@diagnostic_redactors[event] ||= Redactor.new(@secrets))
      data = redactor.append(data)
      return if data.empty?
    end
    trace("#{event} #{data.inspect}", level: level, event: event)
  end

  # 诊断与接收字节日志分开；回调元数据不含会话对象，避免格式化时意外展开原始缓冲。
  def trace(message, level: 1, event: :matched)
    return unless debug_level >= level

    severity = level == 1 ? :info : :debug
    target = diagnostic_output
    if target.respond_to?(:info) && target.respond_to?(:debug)
      target.public_send(severity, "#{inspect}: #{message}")
    elsif target.respond_to?(:call)
      target.call({ event: event, level: severity, pid: pid, fd: fileno, message: message.freeze }.freeze)
    elsif target
      emit(target, "#{inspect}: #{message}\n")
    else
      warn("#{inspect}: #{message}")
    end
  end

  # 结束当前日志片段并交付过滤器尾部；重复调用不会重放已释放字节，写入异常原样传播。
  def flush_log
    loop do
      return unless @log_redactor && log_output

      data = @log_redactor.finish
      return if data.empty?

      log_output.respond_to?(:call) ? log_output.call(data) : emit(log_output, data)
      # 回调可能轮换目标并追加新尾部；先结束它，再允许外层截断文件或关闭日志。
    end
  end

  # EOF 只结束接收诊断；目标替换或显式关闭结束全部方向，发送与接收不能拼成一个秘密。
  # GC 终结器不进入本方法，避免在回收阶段调用用户回调或持有会话对象。
  def flush_diagnostics(event = nil)
    return unless @diagnostic_redactors

    loop do
      delivered = false
      # 回调可能首次创建另一个方向，也可能写入本轮已经处理的方向。
      @diagnostic_redactors.to_a.each do |name, redactor|
        next if event && name != event

        data = redactor.finish
        next if data.empty?

        delivered = true
        trace("#{name} #{data.inspect}", level: 2, event: name)
      end
      # 目标尚未交接，新产生的尾部仍归旧诊断流；排空后才结束这次冲刷。
      break unless delivered
    end
  end

  # 交接日志目标和所有权，只关闭库拥有的旧文件；失败时释放新打开的文件。
  def replace_log(target, owned: false)
    # 重复赋值同一目标时保留原所有权，防止将库打开的文件误变成借用资源。
    return target if log_output.equal?(target)

    flush_log
    # 尾部回调可以重入并替换目标；交接时重新读取目标和所有权，不能关闭旧的回调对象。
    return target if log_output.equal?(target)

    previous = @resources.owned_log
    previous.close if previous && !previous.closed?
    # 终结器只持有所属文件；借用回调可能捕获会话，不能让它经资源对象成为 GC 根。
    @resources.owned_log = owned ? target : nil
    @log_output = target
    @log_redactor = nil
    target
  rescue Exception # rubocop:disable Lint/RescueException -- 替换失败时仍释放刚打开的文件。
    target.close if owned && target && !target.closed?
    raise
  end
end
