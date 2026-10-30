# frozen_string_literal: true

module Expect
  # 可复用的自动应答规则；声明不持有会话，每次等待独立统计应答次数。
  # 输入按字节位置处理，同位置的完成模式优先，其余按规则声明顺序。
  class Responder
    # 规则超限或匹配空文本时停止自动发送，避免反复确认和零宽应答循环。
    class ResponseError < StandardError; end

    # 建立规则集；块保留调用方 self，通过参数注册规则。
    def initialize
      @rules = []
      yield self if block_given?
    end

    # 注册字面或正则提示；reply 原样写入，换行须显式包含，也可用块操作匹配会话。
    # limit 是本规则在一次 expect 中允许的应答次数，nil 不限；规则文本和静态回复复制冻结。
    def on(pattern, reply: nil, limit: nil, &block)
      raise FrozenError, "responder is frozen" if frozen?
      unless (pattern.is_a?(String) && !pattern.empty?) || pattern.is_a?(Regexp)
        raise ArgumentError, "response pattern must be a nonempty String or Regexp"
      end

      validate_action!(reply, limit, block)

      pattern = pattern.b.freeze if pattern.is_a?(String)
      @rules << [pattern, reply&.b&.freeze, limit, block].freeze
      self
    end

    # 等待完成模式或 EOF，同时自动处理提示；timeout 沿用会话默认值，应答不重置期限。
    # 完成块使用 PatternList DSL；Result 只描述最后一次匹配，全文请用会话 transcript 保存。
    # 每次等待快照规则，回调修改规则仅影响后续等待；不接管或关闭会话。
    def expect(session, *patterns, timeout: (session.timeout if session.is_a?(Session)), deadline: nil,
               search_window: nil, &block)
      raise ArgumentError, "responder requires a Session" unless session.is_a?(Session)

      raise ArgumentError, "provide patterns or a pattern block, not both" if block && !patterns.empty?

      rules = @rules.dup.freeze
      Expect.run_expect(
        [session], [], timeout, deadline:, consume: true,
                                reset_timeout_on_read: false, match_by_position: true, search_window:
      ) do |list|
        patterns.each do |pattern|
          case pattern
          when :eof then list.eof
          when :timeout then list.timeout
          else list.on(pattern)
          end
        end
        if block
          block.parameters.empty? ? list.instance_exec(&block) : block.call(list)
        end
        unless list.sessions.all? { |source| source.equal?(session) }
          raise ArgumentError, "response completion patterns must use the same Session"
        end

        register(list, rules)
      end
    end

    # 摘要不展示模式、回复或回调闭包，避免意外记录凭据。
    def inspect = "#<#{self.class} rules=#{@rules.size}>"

    private

    # 静态回复与动作块互斥，次数必须是明确的正整数，不做宽松转换。
    def validate_action!(reply, limit, block)
      unless (reply.is_a?(String) && !block) || (reply.nil? && block)
        raise ArgumentError, "provide a String reply or a response block, not both"
      end
      return if limit.nil? || (limit.is_a?(Integer) && limit.positive?)

      raise ArgumentError, "response limit must be a positive Integer"
    end

    # 计数只属于本轮；先检查再发送，不重试写入或回调失败的部分副作用。
    def register(list, rules)
      rules.each_with_index do |(pattern, reply, limit, block), index|
        count = 0
        list.on(pattern) do |session|
          raise ResponseError, "response rule #{index + 1} matched empty text" if session.match.empty?
          raise ResponseError, "response rule #{index + 1} exceeded its limit" if limit && count >= limit

          count += 1
          block ? block.call(session) : session.write(reply)
          CONTINUE_WITHOUT_RESET
        end
      end
    end
  end
end
