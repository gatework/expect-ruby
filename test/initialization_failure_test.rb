# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class InitializationFailureTest < ExpectTest
  def test_new_closes_both_pty_ends_before_propagating_the_original_exception
    initialization_errors.each do |failure|
      master, slave = PTY.open
      @ios.push(master, slave)
      PTY.stub(:open, [master, slave]) do
        without_ledger(failure) do
          assert_same failure, assert_raises(failure.class) { Expect.new }
          assert master.closed?, "master leaked before test cleanup"
          assert slave.closed?, "slave leaked before test cleanup"
        end
      end
    end
  end

  def test_open_cleans_owned_handles_and_preserves_borrowed_handles
    [true, false].product(initialization_errors).each do |own, failure|
      reader, writer = IO.pipe
      @ios.push(reader, writer)
      without_ledger(failure) do
        assert_same failure, assert_raises(failure.class) { Expect.open(reader, writer: writer, own: own) }
        assert_equal own, reader.closed?
        assert_equal own, writer.closed?
      end
    end
  end

  def test_duplicate_owned_handle_is_attempted_once_even_when_close_fails
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    calls = 0
    reader.stub(:close, lambda {
      calls += 1
      raise IOError, "injected close failure"
    }) do
      without_ledger(failure = Interrupt.new) do
        assert_same failure, assert_raises(Interrupt) { Expect.open(reader, own: true) }
        assert_equal 1, calls
      end
    end
  end

  def test_cleanup_failure_still_attempts_other_handles_and_keeps_primary_exception
    initialization_errors.each do |failure|
      reader, writer = IO.pipe
      @ios.push(reader, writer)
      reader.stub(:close, -> { raise Errno::EIO }) do
        without_ledger(failure) do
          assert_same failure, assert_raises(failure.class) { Expect.open(reader, writer: writer, own: true) }
          assert writer.closed?
        end
      end
    end
  end

  def test_new_cleanup_failure_still_closes_slave
    master, slave = PTY.open
    @ios.push(master, slave)
    PTY.stub(:open, [master, slave]) do
      master.stub(:close, -> { raise IOError, "injected close failure" }) do
        without_ledger(failure = SystemExit.new(17)) do
          assert_same failure, assert_raises(SystemExit) { Expect.new }
          assert slave.closed?
        end
      end
    end
  end

  def test_invalid_non_io_argument_is_not_closed_by_the_fallback
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    invalid = Object.new
    invalid.define_singleton_method(:close) { raise "must not close non-IO objects" }
    without_ledger(failure = Interrupt.new) do
      assert_same failure, assert_raises(Interrupt) { Expect.open(invalid, writer: writer, own: true) }
      assert writer.closed?
    end
  end

  private

  def initialization_errors = [Interrupt.new("injected initialization interruption"), SystemExit.new(17)]

  def without_ledger(failure, &)
    Expect::SessionResources.stub(:new, ->(*, **) { raise failure }, &)
  end
end
