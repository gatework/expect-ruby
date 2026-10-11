# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class InteractCleanupTest < ExpectTest
  def setup
    super
    @session, = pipe_session
    master, @terminal = PTY.open
    @ios.push(master, @terminal)
    @source = Expect.open(@terminal)
    @sessions << @source
    @mode = @terminal.console_mode
    @settings = terminal_configuration(@source)
    @session.outputs = [StringIO.new]
    @source.outputs = [StringIO.new]
    @source.on_sequence("original")
    @outputs = [@session.outputs, @source.outputs]
    @sequences = @source.sequences.dup
  end

  def teardown
    @terminal.console_mode = @mode unless @terminal.closed?
    super
  end

  def test_callback_failure_survives_terminal_restore_failure
    [ArgumentError.new("callback failed"), Interrupt.new("cancelled"), SystemExit.new(17)].each do |primary|
      @session.buffer = "!tail"
      @session.on_sequence("!") { raise primary }
      restores = 0
      @terminal.stub(:console_mode=, lambda { |_mode|
        restores += 1
        raise Errno::EIO, "terminal restoration failed"
      }) do
        assert_same primary, assert_raises(primary.class) { interact }
      end

      assert_equal 1, restores
      assert_equal "tail", @session.buffer
      assert_settings_restored
      @terminal.console_mode = @mode
    end
  end

  def test_restore_failure_without_a_callback_failure_is_reported
    failure = Errno::EIO.new("terminal restoration failed")
    @terminal.stub(:console_mode=, ->(_mode) { raise failure }) do
      assert_same failure, assert_raises(Errno::EIO) { interact }
    end
    assert_settings_restored
  end

  def test_new_interrupt_during_restoration_is_not_hidden
    @session.buffer = "!tail"
    @session.on_sequence("!") { raise ArgumentError, "callback failed" }
    failure = Interrupt.new("restoration interrupted")
    @terminal.stub(:console_mode=, ->(_mode) { raise failure }) do
      assert_same failure, assert_raises(Interrupt) { interact }
    end
    assert_settings_restored
  end

  def test_each_setting_is_restored_even_when_an_output_restore_fails
    outputs = @session.outputs
    original = @session.method(:outputs=)
    failure = IOError.new("output restoration failed")
    @session.stub(:outputs=, lambda { |targets|
      raise failure if targets == outputs

      original.call(targets)
    }) do
      assert_same failure, assert_raises(IOError) { interact }
    end
    assert_equal @outputs.last, @source.outputs
    assert_equal @sequences, @source.sequences
    assert_equal @settings, terminal_configuration(@source)
  end

  def test_cancellation_at_terminal_state_handoff_leaves_the_terminal_restored
    trace = nil
    %i[raise kill].each do |cancellation|
      arrived = Queue.new
      hold = Queue.new
      trace = TracePoint.new(:return) do |event|
        next unless event.method_id == :prepare_interact_terminal && event.self.equal?(@session)

        trace.disable
        arrived << true
        hold.pop
      end
      worker = background do
        trace.enable(target_thread: Thread.current) { interact }
      rescue Interrupt
        :cancelled
      end
      bounded { arrived.pop }
      cancellation == :raise ? worker.raise(Interrupt, "cancel handoff") : worker.kill
      assert(bounded { worker.join })

      assert_equal @settings, terminal_configuration(@source), "terminal changed after #{cancellation}"
      assert_settings_restored
    end
  ensure
    trace&.disable
  end

  private

  def interact
    @session.interact(input: @source, output: StringIO.new, escape: "temporary", timeout: 0)
  end

  def assert_settings_restored
    assert_equal @outputs, [@session.outputs, @source.outputs]
    assert_equal @sequences, @source.sequences
    assert_nil @session.relay_owner
    assert_nil @source.relay_owner
  end
end
