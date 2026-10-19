# frozen_string_literal: true

module Expect
  # 一个连续字节窗口的字面未命中进度；不持有输入、会话或 IO。
  # Matcher 的窗口只追加，Relay 还会移出安全前缀，两者共用绝对字节坐标。
  # @api private
  class LiteralScan
    def initialize
      @misses = {}.compare_by_identity
      @consumed = 0
      @generation = nil
    end

    # 返回相对当前窗口的字节位置；新输入只重扫可能跨越旧尾部的重叠区。
    # literal 须为冻结的二进制 String，generation 变化表示窗口被替换、裁剪或外部消费。
    def index(buffer, literal, generation:)
      if @generation != generation
        reset
        @generation = generation
      end
      ending = @consumed + buffer.bytesize
      previous = @misses[literal]
      return nil if previous == ending

      offset = previous ? [previous - @consumed - literal.bytesize + 1, 0].max : 0
      position = buffer.index(literal, offset)
      if position
        @misses.delete(literal)
      else
        @misses[literal] = ending
      end
      position
    end

    # Relay 仅移出已扫描的安全前缀；未命中范围仍有效，无须逐规则调整偏移。
    def advance(count)
      @consumed += count
    end

    # 转义消费或外部修改建立新边界，后续扫描不能复用旧输入的结论。
    def reset
      @misses.clear
      @consumed = 0
      @generation = nil
    end
  end
  private_constant :LiteralScan
end
