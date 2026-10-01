# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class WriteContractTest < ExpectTest
  def test_invalid_write_counts_fail_on_the_first_attempt
    [0, -1, nil, "3", 4].each do |invalid|
      session, = writable_session
      attempts = 0
      session.writer.stub(:write_nonblock, lambda { |*, **|
        attempts += 1
        invalid
      }) do
        error = assert_raises(IOError) { bounded(0.2) { session.write("abc") } }
        refute_kind_of Expect::WriteTimeout, error
        assert_match(/accepted bytes/, error.message)
        assert_equal 1, attempts
      end
    end
  end

  def test_count_is_checked_against_the_attempted_chunk_not_the_total_input
    session, = writable_session
    session.writer.stub(:write_nonblock, lambda { |chunk, **|
      assert_equal Expect::READ_SIZE, chunk.bytesize
      chunk.bytesize + 1
    }) do
      assert_raises(IOError) { session.write("x" * (Expect::READ_SIZE + 1)) }
    end
  end

  def test_successful_short_writes_can_outlive_the_backpressure_deadline
    session, sink = writable_session(write_timeout: 0.01)
    now = 0.0
    original = session.writer.method(:write_nonblock)
    Expect.stub(:monotonic, -> { now }) do
      session.writer.stub(:write_nonblock, lambda { |chunk, **options|
        count = original.call(chunk.byteslice(0, 1), **options)
        now += 0.02
        count
      }) do
        assert_equal 3, session.write("abc")
      end
    end
    assert_in_delta 0.06, now
    assert_equal("abc", bounded { sink.read(3) })
  end

  def test_empty_input_never_attempts_a_write
    session, = writable_session(write_timeout: 0)
    session.writer.stub(:write_nonblock, ->(*, **) { flunk "empty input reached writer" }) do
      assert_equal 0, session.write
      assert_equal 0, session.write("")
    end
  end

  def test_valid_short_writes_and_eintr_preserve_every_byte
    session, sink = writable_session
    original = session.writer.method(:write_nonblock)
    attempts = 0
    session.writer.stub(:write_nonblock, lambda { |chunk, **options|
      attempts += 1
      raise Errno::EINTR if attempts == 2

      original.call(chunk.byteslice(0, 1), **options)
    }) do
      assert_equal(4, bounded { session.write("a\0\xffb".b) })
    end
    assert_equal 5, attempts
    assert_equal("a\0\xffb".b, bounded { sink.read(4) })
  end

  def test_backpressure_reports_only_confirmed_progress
    session, sink = writable_session(write_timeout: 0.01)
    original = session.writer.method(:write_nonblock)
    now = 0.0
    attempts = 0
    Expect.stub(:monotonic, -> { now }) do
      session.writer.stub(:write_nonblock, lambda { |chunk, **options|
        attempts += 1
        next :wait_writable if attempts > 1

        now = 0.02
        original.call(chunk.byteslice(0, 1), **options)
      }) do
        error = assert_raises(Expect::WriteTimeout) { bounded { session.write("abc") } }
        assert_equal 1, error.bytes_written
      end
    end
    assert_equal 2, attempts
    assert_equal("a", bounded { sink.read(1) })
  end

  private

  def writable_session(**)
    reader, producer = IO.pipe
    sink, writer = IO.pipe
    @ios.push(reader, producer, sink, writer)
    session = Expect.open(reader, writer:, **)
    @sessions << session
    [session, sink]
  end
end
