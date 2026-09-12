# frozen_string_literal: true

# 为会话补充人工接管和多路 IO 转接；核心会话定义位于 lib/expect.rb。
class Expect
  # 注册字面、正则转义或 :eof 事件；回调用闭包保存上下文，nil/false 停止，其余值继续。
  def on_sequence(sequence, &block)
    key = case sequence
          when :eof, Regexp then sequence
          when String then sequence.b.freeze
          else raise ArgumentError, "sequence must be a String, Regexp or :eof"
          end
    raise ArgumentError, "escape sequence must not be empty" if key == ""

    @sequences[key] = block
    self
  end

  # 临时将输入、会话和输出相连，实现人工接管；结束时恢复双方监听器、日志开关和转义设置。
  def interact(input: $stdin, escape: nil, output: nil, timeout: nil)
    source = input.is_a?(Expect) ? input : Expect.open(input)
    output ||= input.equal?($stdin) ? $stdout : input
    saved_self = [listeners, log_stdout, log_listeners]
    saved_source = [source.listeners, source.log_stdout, source.log_listeners, source.sequences.dup]
    # 临时建立“用户输入 -> 子进程 -> 显示输出”的双向连接，原监听关系在 ensure 中恢复。
    self.listeners = [output]
    self.log_stdout = false
    self.log_listeners = true
    source.listeners = [self]
    source.log_stdout = false
    source.log_listeners = true
    source.on_sequence(escape) if escape
    Expect.interconnect(self, source, timeout: timeout)
  ensure
    if saved_self
      self.listeners, self.log_stdout, self.log_listeners = saved_self
      source.listeners, source.log_stdout, source.log_listeners, source.sequences = saved_source
    end
  end

  # 按各会话 listeners 建立转发图，处理转义、EOF 和总期限，返回引发停止的会话或 nil。
  def self.interconnect(*sessions, timeout: nil)
    raise ArgumentError, "interconnect requires Expect sessions" if sessions.empty? || sessions.any? do |session|
      !session.is_a?(Expect)
    end

    period = duration(timeout)
    deadline = period && (monotonic + period)
    active = sessions.uniq
    # buffers 保存尚未转发的字节，histories 保存正则跨读取所需的已转发前缀。
    # 接管原匹配缓冲时只转发，日志已在实际读取时记录，不能重复写入。
    buffers = active.to_h { |session| [session, session.clear_buffer] }
    histories = active.to_h { |session| [session, "".b] }
    terminal_objects = active.flat_map { |session| [session, *session.listeners] }.uniq
    saved = []
    polled = false
    begin
      terminal_objects.each do |object|
        next if object.is_a?(Expect) && !object.raw_terminal?

        io = object.respond_to?(:to_io) ? object.to_io : object
        next unless io.respond_to?(:tty?) && io.tty?
        next if saved.any? { |entry| entry.first.equal?(io) }

        # 修改前先保存模式，同一个 IO 对象只保存一次，部分初始化失败也能恢复。
        saved << [io, io.console_mode]
        io.raw!
      end

      loop do
        active.dup.each do |session|
          return session unless relay_buffer(session, buffers, histories, final: session.eof?)
          next unless session.eof?

          # EOF 回调为真才继续监听其他源，当前结束源随后移出 active。
          callback = session.__send__(:sequences)[:eof]
          return session unless callback&.call

          active.delete(session)
        end
        return nil if active.empty?

        remaining = deadline && [deadline - monotonic, 0].max
        ready = polled && remaining&.zero? ? nil : IO.select(active.map(&:to_io), nil, nil, remaining)
        polled = true
        unless ready
          # 到期后不会再等转义的后半段，将暂存的字面前缀作为普通输入转发。
          buffers.each do |session, buffer|
            session.__send__(:propagate, buffer) unless buffer.empty?
            buffer.clear
          end
          return nil
        end
        ready[0].each do |io|
          session = active.find { |candidate| candidate.to_io.equal?(io) }
          data = session.__send__(:read_available, propagate: false, accumulate: false)
          buffers[session] << data if data
        end
      end
    ensure
      # 转义后的尾部归下次 expect/interact 使用；无论正常返回还是异常，都归还缓冲并恢复终端。
      buffers.each { |session, buffer| session.buffer = buffer + session.buffer }
      saved.reverse_each { |io, mode| io.console_mode = mode unless io.closed? }
    end
  end

  # 转发一个会话的待处理缓冲并剔除转义；返回 false 表示应结束整个转接。
  # 字面序列暂存潜在前缀，正则序列结合历史匹配；final 为真时不再等待后续字节。
  def self.relay_buffer(session, buffers, histories, final: false)
    buffer = buffers.fetch(session)
    history = histories.fetch(session)
    sequences = session.__send__(:sequences).except(:eof)
    loop do
      matches = sequences.filter_map do |key, handler|
        if key.is_a?(Regexp)
          position = Pattern.new(value: key).locate(history + buffer)
          if position
            offset, length, = position
            raise ArgumentError, "escape regexp must consume at least one byte" if length.zero?

            # 历史前缀已实时转发，不能撤回；负偏移表示本次只需消费转义尚未转发的部分。
            [offset - history.bytesize, length, handler]
          end
        else
          position = buffer.index(key)
          [position, key.bytesize, handler] if position
        end
      end
      if (found = matches.min_by(&:first))
        position, length, callback = found
        session.__send__(:propagate, buffer.byteslice(0, position)) if position.positive?
        buffer.replace(buffer.byteslice([position + length, 0].max..))
        # 转义消费后清除历史，防止继续回调再次匹配同一个转义。
        history.clear
        return false unless callback&.call

        next
      end

      # 暂存可能构成字面转义的最长后缀，保证 STOP 分两次读取时 ST 不会提前发给子进程。
      held = 0
      unless final
        sequences.each_key do |key|
          next if key.is_a?(Regexp)

          [key.bytesize - 1, buffer.bytesize].min.downto(1) do |length|
            if buffer.end_with?(key.byteslice(0, length))
              held = [held, length].max
              break
            end
          end
        end
      end
      count = buffer.bytesize - held
      session.__send__(:propagate, buffer.byteslice(0, count)) if count.positive?
      if sequences.keys.any?(Regexp)
        history << buffer.byteslice(0, count)
        limit = session.buffer_limit
        history.replace(history.byteslice(-limit, limit)) if limit && history.bytesize > limit
      end
      buffer.replace(held.zero? ? "".b : buffer.byteslice(-held, held))
      return true
    end
  end
  private_class_method :relay_buffer

  protected

  # 仅供转接内部保存和恢复注册表，避免公开可变 Hash 绕过 on_sequence 的校验。
  attr_accessor :sequences
end
