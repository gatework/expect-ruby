# frozen_string_literal: true

require_relative "test_helper"

class GracefulFactoryCleanupTest < ExpectTest
  def test_block_failure_skips_graceful_reading_and_preserves_the_primary_error
    %i[spawn open].each do |kind|
      [RuntimeError.new("block failed"), Interrupt.new("cancelled"), SystemExit.new(17)].each do |primary|
        waits = []
        error = assert_raises(primary.class) do
          with_graceful_factory(kind, waits) { raise primary }
        end
        assert_same primary, error
        assert_empty waits, "#{kind} drained input after block failure"
        assert_closed_factory_session
      end
    end
  end

  def test_throw_skips_graceful_reading
    %i[spawn open].each do |kind|
      waits = []
      value = catch(:stop) { with_graceful_factory(kind, waits) { throw :stop, :cancelled } }
      assert_equal :cancelled, value
      assert_empty waits
      assert_closed_factory_session
    end
  end

  def test_break_skips_graceful_reading
    %i[spawn open].each do |kind|
      waits = []
      assert_equal :cancelled, with_graceful_factory(kind, waits) { break :cancelled }
      assert_empty waits
      assert_closed_factory_session
    end
  end

  def test_return_skips_graceful_reading
    %i[spawn open].each do |kind|
      waits = []
      assert_equal :cancelled, return_from_factory(kind, waits)
      assert_empty waits
      assert_closed_factory_session
    end
  end

  def test_thread_kill_skips_graceful_reading
    %i[spawn open].each do |kind|
      waits = []
      entered = Queue.new
      release = Queue.new
      worker = background do
        with_graceful_factory(kind, waits) do
          entered << true
          release.pop
        end
      end
      bounded { entered.pop }
      worker.kill
      bounded { worker.join }
      assert_empty waits
      assert_closed_factory_session
    end
  end

  def test_normal_completion_inside_rescue_still_drains_and_preserves_false_or_nil
    %i[spawn open].each do |kind|
      [false, nil].each do |value|
        waits = []
        begin
          raise "already handled"
        rescue RuntimeError
          actual = with_graceful_factory(kind, waits) { value }
          assert_same value, actual
        end
        refute_empty waits, "#{kind} skipped graceful reading after normal completion"
        assert_closed_factory_session
      end
    end
  end

  def test_thread_raise_skips_graceful_reading_and_preserves_the_primary_error
    %i[spawn open].each do |kind|
      waits = []
      entered = Queue.new
      release = Queue.new
      primary = Interrupt.new("factory cancelled")
      worker = background do
        with_graceful_factory(kind, waits) do
          entered << true
          release.pop
        end
      rescue Interrupt => error
        error
      end
      bounded { entered.pop }
      worker.raise(primary)
      assert_same(primary, bounded { worker.value })
      assert_empty waits
      assert_closed_factory_session
    end
  end

  def test_normal_open_completion_drains_real_tail_output
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    writer.write("tail")
    writer.close
    transcript = StringIO.new
    value = Expect.open(reader, own: true, graceful: true, transcript:) do |session|
      @sessions << session
      :finished
    end
    assert_equal :finished, value
    assert_equal "tail", transcript.string
    assert_closed_factory_session
    refute transcript.closed?
  end

  private

  # 只替换可能等待 15 秒的 IO 边界；工厂、资源关闭与子进程回收使用真实实现。
  def with_graceful_factory(kind, waits, &action)
    operation = lambda do |session|
      @sessions << session
      assert session.expect("ready", timeout: 2).matched? if kind == :spawn
      session.to_io.define_singleton_method(:wait_readable) do |*|
        waits << :drain
        false
      end
      action.call(session)
    end
    if kind == :spawn
      Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", 'STDOUT.sync = true; puts "ready"; sleep 60',
                   raw: true, graceful: true, &operation)
    else
      reader, writer = IO.pipe
      @ios.push(reader, writer)
      Expect.open(reader, own: true, graceful: true, &operation)
    end
  end

  def return_from_factory(kind, waits)
    with_graceful_factory(kind, waits) { return :cancelled }
  end

  def assert_closed_factory_session
    session = @sessions.last
    assert session.closed?
    assert session.to_io.closed?
    assert_nil session.pid
  end
end
