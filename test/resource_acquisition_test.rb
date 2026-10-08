# frozen_string_literal: true

require_relative "test_helper"

class ResourceAcquisitionTest < ExpectTest
  def test_interruption_after_pty_open_closes_both_handles
    failure = Interrupt.new("interrupted after PTY.open")
    assert_same(failure, interrupt_acquisition(PTY, :open) { |owner| owner.raise(failure) })
  end

  def test_thread_termination_after_pty_open_closes_both_handles
    assert_nil interrupt_acquisition(PTY, :open, &:kill)
  end

  def test_interruption_after_error_pipe_creation_closes_both_handles
    failure = Interrupt.new("interrupted after IO.pipe")
    assert_same(failure, interrupt_acquisition(IO, :pipe) { |owner| owner.raise(failure) })
  end

  def test_thread_termination_after_error_pipe_creation_closes_both_handles
    assert_nil interrupt_acquisition(IO, :pipe, &:kill)
  end

  def test_interruption_when_initialized_session_returns_to_factory_closes_its_handles
    failure = Interrupt.new("interrupted after Session initialization")
    assert_same(failure, interrupt_factory { |owner| owner.raise(failure) })
  end

  def test_thread_termination_when_initialized_session_returns_to_factory_closes_its_handles
    assert_nil interrupt_factory(&:kill)
  end

  def test_thread_termination_before_initialization_keeps_the_factory_cleanup_safe
    assert_nil interrupt_factory(event: :call, &:kill)
  end

  def test_factory_initialization_does_not_defer_interrupts_in_user_protocols
    failure = Interrupt.new("interrupted while validating logger")
    logger = Object.new
    resumed = false
    logger.define_singleton_method(:respond_to_missing?) do |*|
      owner = Thread.current
      Thread.new { owner.raise(failure) }.join
      resumed = true
    end

    assert_same(failure, assert_raises(Interrupt) do
      Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "exit 0", logger:)
    end)
    refute resumed
  end

  private

  # 初始化器已交出清理责任，工厂也必须已经持有会话；不能依靠等待 GC 关闭 PTY。
  def interrupt_factory(event: :return, &interrupt)
    gate = Queue.new
    owner = background do
      gate.pop
      Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "exit 0")
    end
    owner.report_on_exception = false
    session = nil
    trace = TracePoint.new(event) do |point|
      next unless point.method_id == :initialize && point.self.is_a?(Expect::Session)

      trace.disable
      session = point.self
      @sessions << session if event == :return
      background { interrupt.call(owner) }.join
    end
    result = trace.enable(target_thread: owner) do
      gate << true
      begin
        bounded { owner.value }
      rescue Interrupt => error
        error
      end
    end
    assert_instance_of Expect::Session, session
    if event == :return
      assert_predicate session, :closed?
      assert_predicate session.to_io, :closed?
      assert_predicate session.slave, :closed?
      assert_nil session.pid
    end
    result
  ensure
    trace&.disable
    owner&.kill&.join if owner&.alive?
  end

  # 原生调用已经创建句柄、Ruby 多重赋值尚未接管时送达中断；不依赖源码行号或 sleep 竞态。
  def interrupt_acquisition(factory, method, &interrupt)
    if factory.equal?(IO)
      session = Expect::Session.new
      @sessions << session
    end
    gate = Queue.new
    owner = background do
      gate.pop
      session ? session.spawn(RbConfig.ruby, "--disable-gems", "-e", "exit 0") : Expect::Session.new
    end
    owner.report_on_exception = false
    handles = []
    trace = TracePoint.new(:c_return) do |point|
      next unless point.self.equal?(factory) && point.method_id == method

      trace.disable
      handles = point.return_value
      @ios.concat(handles)
      background { interrupt.call(owner) }.join
    end
    result = trace.enable(target_thread: owner) do
      gate << true
      begin
        bounded { owner.value }
      rescue Interrupt => error
        error
      end
    end
    assert_equal 2, handles.size
    handles.each { |io| assert_predicate io, :closed? }
    assert_nil session.pid if session
    result
  ensure
    trace&.disable
    owner&.kill&.join if owner&.alive?
  end
end
