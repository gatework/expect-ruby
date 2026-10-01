# frozen_string_literal: true

require "logger"
require_relative "redactor"

# 借用标准 Logger、接收记录 writer 和协议输出 writer，不接管它们的生命周期。
# 脱敏只作用于诊断与接收记录，协议输出和匹配缓冲始终保留原始字节。
module Expect
  # 会话诊断、接收记录和协议转发的独立输出接口。
  module Logging
    # 调用方提供的诊断 Logger 与原始接收记录 writer，均由调用方管理生命周期。
    attr_reader :logger, :transcript

    # Logger 自己决定级别、格式与失败策略；nil 禁用诊断，不隐式写入 stderr。
    # 替换前先完成旧流脱敏，失败时仍保留旧 logger。
    def logger=(target)
      unless target.nil? || (target.respond_to?(:add) && target.respond_to?(:debug?))
        raise ArgumentError, "logger must support add and debug?, or be nil"
      end
      return if @logger.equal?(target)

      flush_diagnostics
      @logger = target
      @diagnostic_redactors = {}
    end

    # 秘密仅作用于本会话的接收记录和诊断，不改写匹配或 outputs 的协议字节。
    # 先校验全部值再发布；注册是追加操作，应在首次通信前完成，不能追溯已交付的日志。
    def redact(*secrets)
      unless secrets.any? && secrets.all? { |secret| secret.is_a?(String) && !secret.empty? }
        raise ArgumentError, "secrets must be nonempty Strings"
      end

      @secrets = ((@secrets || []) + secrets.map { |secret| secret.b.freeze }).uniq.freeze
      @transcript_redactor.patterns = @secrets if @transcript_redactor
      @diagnostic_redactors.each_value { |redactor| redactor.patterns = @secrets }
      self
    end

    # 接收记录只采用 write 协议；文件打开、权限和关闭由调用方管理。
    def transcript=(target)
      raise ArgumentError, "transcript must support write, or be nil" unless target.nil? || target.respond_to?(:write)
      return if @transcript.equal?(target)

      flush_transcript
      @transcript = target
      @transcript_redactor = nil
    end

    # 向接收记录补写内容，不发送给子进程或 outputs；脱敏尾部可能延迟交付，返回 nil。
    def write_transcript(*objects)
      target = transcript
      return unless target

      data = objects.map { |object| object.to_s.b }.join
      if @secrets
        @transcript_redactor ||= Redactor.new(@secrets)
        data = @transcript_redactor.append(data)
        return if data.empty?
      end
      emit(target, data)
      nil
    end

    # 返回副本，避免外部原地修改转发关系；stdout 与其他 writer 使用相同协议。
    def outputs = @outputs.dup

    # 先校验整个数组再替换，失败时保留原输出图。
    def outputs=(targets)
      unless targets.is_a?(Array) && targets.all? { |target| target.respond_to?(:write) }
        raise ArgumentError, "outputs must be an Array of writers"
      end

      @outputs = targets.dup
    end

    # 原样转发协议字节，接收记录在读取时单独写入。
    # @api private
    def propagate(data)
      @outputs.each { |output| emit(output, data) }
    end

    private

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

    # 字节诊断在 inspect 转义之前过滤，发送与接收各自保留分片状态。
    def trace_data(event, data)
      return unless logger&.debug?

      if @secrets
        redactor = (@diagnostic_redactors[event] ||= Redactor.new(@secrets))
        data = redactor.append(data)
        return if data.empty?
      end
      trace("#{event} #{data.inspect}", severity: Logger::DEBUG, event:)
    end

    # 向标准 Logger 提交不可变事件，不包含会话对象；格式化由 logger 完成。
    def trace(message, severity: Logger::INFO, event: :matched)
      logger&.add(severity, { event:, pid:, fd: fileno, message: message.freeze }.freeze, "Expect")
    end

    # 结束当前日志片段并交付过滤器尾部；重复调用不会重放已释放字节，写入异常原样传播。
    def flush_transcript
      loop do
        return unless @transcript_redactor && transcript

        data = @transcript_redactor.finish
        return if data.empty?

        emit(transcript, data)
        # writer 可能重入并追加尾部；交接前仍归当前记录流。
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
          trace("#{name} #{data.inspect}", severity: Logger::DEBUG, event: name)
        end
        # 目标尚未交接，新产生的尾部仍归旧诊断流；排空后才结束这次冲刷。
        break unless delivered
      end
    end
  end
end
