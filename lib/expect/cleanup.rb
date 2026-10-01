# frozen_string_literal: true

module Expect
  # 清理作用域只记录本次异常，不受调用者 rescue 中的旧 $! 影响。
  # @api private
  module Cleanup
    # 包括非局部返回在内的所有退出均清理；StandardError 只在没有原异常时传播。
    # 清理期间新发生的 Interrupt、SystemExit 等致命异常仍原样传播。
    def self.always(on_exit)
      yield
    rescue Exception # rubocop:disable Lint/RescueException -- 中断也必须清理，然后原样传播。
      failed = true
      raise
    ensure
      begin
        on_exit.call
      rescue StandardError
        raise unless failed
      end
    end

    # 完成初始化或交接后释放清理责任；异常与非局部退出仍回滚未发布资源。
    def self.on_failure(on_exit)
      completed = false
      always(-> { on_exit.call unless completed }) do
        result = yield
        completed = true
        result
      end
    end
  end

  private_constant :Cleanup
end
