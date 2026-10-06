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

  def test_nested_timeout_before_sending_reports_the_commands_own_progress
    %i[diagnostic conversion].each do |boundary|
      session, sink = writable_session
      diagnostic, diagnostic_sink = writable_session(write_timeout: 0)
      nested_write = ->(*) { diagnostic.write("event") }
      command = "command"
      if boundary == :diagnostic
        session.logger = diagnostic_logger(&nested_write)
      else
        command = Object.new
        command.define_singleton_method(:to_s) do
          nested_write.call
          "command"
        end
      end
      original = diagnostic.writer.method(:write_nonblock)
      attempts = 0

      error = diagnostic.writer.stub(:write_nonblock, lambda { |chunk, **options|
        attempts += 1
        attempts == 1 ? original.call(chunk.byteslice(0, 2), **options) : :wait_writable
      }) do
        assert_raises(Expect::WriteTimeout) { bounded { session.write(command) } }
      end

      assert_equal 0, error.bytes_written
      assert_instance_of Expect::WriteTimeout, error.cause
      assert_equal 2, error.cause.bytes_written
      assert_equal "ev", diagnostic_sink.read(2)
      assert_equal :wait_readable, sink.read_nonblock(1, exception: false)
      session.logger = nil
      assert_equal 7, session.write("command")
      assert_equal "command", sink.read(7)
    end
  end

  def test_slow_send_timeout_includes_previous_characters_and_partial_current_character
    session, sink = writable_session(write_timeout: 0)
    original = session.writer.method(:write_nonblock)
    attempts = 0
    error = session.writer.stub(:write_nonblock, lambda { |chunk, **options|
      attempts += 1
      case attempts
      when 1 then original.call(chunk, **options)
      when 2 then original.call(chunk.byteslice(0, 1), **options)
      else :wait_writable
      end
    }) do
      assert_raises(Expect::WriteTimeout) { session.send_slow("a中b", delay: 0) }
    end

    assert_equal 2, error.bytes_written
    assert_equal 1, error.cause.bytes_written
    assert_equal "a\xe4".b, sink.read_nonblock(100)
    assert_equal 3, session.write("a中b".b.byteslice(error.bytes_written..))
    assert_equal "\xb8\xadb".b, sink.read_nonblock(100)
  end

  def test_slow_send_conversion_timeout_excludes_unrelated_nested_progress
    session, sink = writable_session
    nested = Expect::WriteTimeout.new(bytes_written: 97)
    object = Object.new
    object.define_singleton_method(:to_s) { raise nested }

    error = assert_raises(Expect::WriteTimeout) { session.send_slow("ab", object, delay: 0) }
    assert_equal 2, error.bytes_written
    assert_same nested, error.cause
    assert_equal "ab", sink.read_nonblock(100)
  end

  def test_slow_send_reply_timeout_reports_its_own_confirmed_progress
    session, sink, producer = writable_session
    nested = Expect::WriteTimeout.new(bytes_written: 97)
    # 回复记录中的写入可能失败，已发出的字符不属于这次内层写入。
    session.transcript = write_target { raise nested }
    producer.write("reply")

    error = assert_raises(Expect::WriteTimeout) { session.send_slow("abc", delay: 0) }
    assert_equal 1, error.bytes_written
    assert_same nested, error.cause
    assert_equal "a", sink.read_nonblock(100)
    assert_equal "reply", session.buffer
  end

  def test_slow_send_first_conversion_timeout_reports_zero_progress
    session, sink = writable_session
    nested = Expect::WriteTimeout.new(bytes_written: 97)
    object = Object.new
    object.define_singleton_method(:to_s) { raise nested }

    error = assert_raises(Expect::WriteTimeout) { session.send_slow(object, delay: 0) }
    assert_equal 0, error.bytes_written
    assert_same nested, error.cause
    assert_equal :wait_readable, sink.read_nonblock(1, exception: false)
  end

  private

  def writable_session(**)
    reader, producer = IO.pipe
    sink, writer = IO.pipe
    @ios.push(reader, producer, sink, writer)
    session = Expect.open(reader, writer:, **)
    @sessions << session
    [session, sink, producer]
  end
end
