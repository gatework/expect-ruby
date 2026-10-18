# frozen_string_literal: true

module Expect
  # 统一管理部分构造对象；调用方只在受保护的移交区间接收已初始化会话。
  # @api private
  module SessionFactory
    def self.pty(**)
      session = nil
      Cleanup.on_failure(-> { session&.cleanup_session(nil, writer: nil, own: false) }) do
        session = Session.allocate
        Thread.handle_interrupt(Object => :immediate) { session.__send__(:initialize, **) }
        session
      end
    end

    def self.io(reader, writer:, own:, **)
      session = nil
      cleanup = lambda do
        if session
          session.cleanup_session(reader, writer:, own:)
        elsif own
          ResourceOwner.close_handles(reader, writer)
        end
      end
      Cleanup.on_failure(cleanup) do
        session = Session.allocate
        Thread.handle_interrupt(Object => :immediate) do
          session.__send__(:initialize_io, reader, writer:, own:, **)
        end
        session
      end
    end
  end
  private_constant :SessionFactory
end
