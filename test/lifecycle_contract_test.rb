# frozen_string_literal: true

require_relative "test_helper"

class LifecycleContractTest < ExpectTest
  def test_external_reaping_releases_pid_without_fabricating_process_status
    session = child('puts "ready"; exit 7', raw: true)
    assert_equal 1, session.expect("ready", timeout: 2).number
    pid = session.pid
    assert_equal(7, bounded { Process.waitpid2(pid).last.exitstatus })
    refute session.alive?
    assert_nil session.pid
    assert_nil session.process_status
    assert_nil session.wait(timeout: 0)
    Process.stub(:kill, ->(*) { flunk "must not signal an externally reaped PID" }) do
      2.times { session.close }
    end
    assert session.closed?
  end

  def test_external_reader_close_does_not_take_ownership_of_the_writer
    reader, producer = IO.pipe
    consumer, writer = IO.pipe
    @ios.push(reader, producer, consumer, writer)
    session = Expect.open(reader, writer:)
    @sessions << session
    session.buffer = "tail"
    reader.close
    assert session.closed?
    assert session.eof?
    refute session.alive?
    assert_raises(IOError) { session.write("blocked") }
    2.times { session.close }
    refute writer.closed?
    assert_equal "tail", session.buffer
    writer.write("borrowed")
    assert_equal "borrowed", consumer.read(8)
  end

  def test_failed_handle_close_can_be_retried_without_losing_other_owned_handles
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    session = Expect.open(reader, writer:, own: true)
    @sessions << session
    failure = IOError.new("close failed")
    reader.stub(:close, -> { raise failure }) do
      assert_same failure, assert_raises(IOError) { session.close }
      assert writer.closed?
      refute reader.closed?
      assert session.closed?
    end
    session.close
    assert reader.closed?
    assert_nil session.close
  end

  def test_timeout_and_eof_remain_events_and_write_errors_remain_io_errors
    session, writer = pipe_session
    timeout = session.expect("missing", timeout: 0)
    assert timeout.timeout?
    assert_equal :timeout, timeout.error
    writer.close
    eof = session.expect(:eof, timeout: 1)
    assert eof.eof?
    assert_equal :eof, eof.error
    failure = Expect::WriteTimeout.new(bytes_written: 3)
    assert_kind_of IOError, failure
    assert_equal 3, failure.bytes_written
    assert_operator Expect::SpawnError, :<, StandardError
  end
end
