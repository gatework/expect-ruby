# frozen_string_literal: true

require "logger"
require_relative "redactor"

# 借用标准 Logger 和接收记录 writer，不接管它们的生命周期。
# 脱敏只作用于诊断与接收记录，协议输出和匹配缓冲始终保留原始字节。
module Expect
  # 会话诊断与接收记录接口；Session 构造时调用本模块初始化过滤器，并提供 pid、fileno 元数据。
  # Logger 接收事件，transcript 接收脱敏字节；Interaction 的协议输出只复用同步 writer 交付。
  module Logging
    # 调用方提供的诊断 Logger 与接收记录 writer，均由调用方管理生命周期。
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
      secrets.map! { |secret| secret.is_a?(String) ? String.new(secret).force_encoding(Encoding::BINARY).freeze : secret }
      unless secrets.any? && secrets.all? { |secret| secret.is_a?(String) && !secret.empty? }
        raise ArgumentError, "secrets must be nonempty Strings"
      end

      @secrets = ((@secrets || []) + secrets).uniq.freeze
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
      return unless transcript

      # 单对象沿用 Session#write 的转换路径，省去数组与 join；转换后仍重新取得目标。
      data = if objects.size == 1
               String.new(objects.first.to_s).force_encoding(Encoding::BINARY)
             else
               objects.map { |object| String.new(object.to_s).force_encoding(Encoding::BINARY) }.join("") # rubocop:disable Style/RedundantArgument -- 显式空分隔符隔离全局 $,。
             end
      # to_s 可切换或禁用记录目标；整条记录与其过滤尾部必须属于转换完成后的同一目标。
      target = transcript
      return unless target

      if @secrets
        @transcript_redactor ||= Redactor.new(@secrets)
        data = @transcript_redactor.append(data)
        return if data.empty?
      end
      emit(target, data)
      nil
    end

    # 转接确认交付后记录发送字节；调用者已登记游标，诊断失败不能回退发送进度。
    # @api private
    def record_sent(data)
      trace_data(:sending, data)
    end

    private

    # 每个日志方向独立保留脱敏状态；协议缓冲及转发图属于 Session 与 Interaction。
    def initialize_logging
      @secrets = @transcript_redactor = nil
      @diagnostic_redactors = {}
      @logger = @transcript = nil
    end

    # 关闭时两种记录都要尝试完成；后续 writer 的常规异常不能覆盖先发生的诊断异常。
    # 不关闭借用目标，新的 Interrupt/SystemExit 仍由 Cleanup 原样传播。
    def finish_logging
      Cleanup.always(-> { self.transcript = nil }) { flush_diagnostics }
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

    # 字节诊断在 inspect 转义之前过滤，发送与接收各自保留分片状态。
    def trace_data(event, data)
      return unless logger

      enabled = logger.debug?

      if @secrets
        redactor = (@diagnostic_redactors[event] ||= Redactor.new(@secrets))
        # 级别变化不切断协议流；关闭期间仍识别秘密，但这些字节以后也不可输出。
        return redactor.suppress(data) unless enabled

        data = redactor.append(data)
        return if data.empty?
      end
      return unless enabled

      trace("#{event} #{data.inspect}", severity: Logger::DEBUG, event:)
    end

    # 向标准 Logger 提交不可变事件，不包含会话对象；格式化由 logger 完成。
    def trace(message = nil, severity: Logger::INFO, event: :matched)
      return unless logger

      message = yield if block_given?
      logger.add(severity, { event:, pid:, fd: fileno, message: message.freeze }.freeze, "Expect")
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
