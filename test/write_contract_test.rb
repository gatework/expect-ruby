# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class WriteContractTest < ExpectTest
  # rubocop:disable Style/SpecialGlobalVars -- 回归覆盖 Ruby 原生全局分隔符。
  def test_multiple_objects_ignore_global_output_separator
    session, sink = writable_session
    previous = $,
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    $, = "|"

    assert_equal 6, session.write("中", nil, "\xFF".b, "ab")
    assert_equal "中\xFFab".b, sink.read(6)
    assert_equal 0, session.write
  ensure
    $, = previous
    $VERBOSE = previous_verbose
  end
  # rubocop:enable Style/SpecialGlobalVars

  def test_callbacks_that_close_borrowed_sessions_prevent_later_protocol_writes
    %i[conversion sending received].each do |boundary|
      client, peer = Socket.pair(:UNIX, :STREAM, 0)
      @ios.push(client, peer)
      session = Expect.open(client)
      @sessions << session
      data = "unexpected"
      if boundary == :conversion
        data = Object.new
        data.define_singleton_method(:to_s) do
          session.close
          "unexpected"
        end
      else
        session.logger = diagnostic_logger { |event| session.close if event[:event] == boundary }
      end
      operation = -> { assert_raises(IOError) { bounded { session.write(data) } } }
      if boundary == :received
        peer.write("incoming")
        original = client.method(:write_nonblock)
        attempts = 0
        client.stub(:write_nonblock, lambda { |chunk, **options|
          attempts += 1
          attempts == 1 ? :wait_writable : original.call(chunk, **options)
        }) { operation.call }
        assert_equal "incoming", session.buffer
      else
        operation.call
      end
      assert session.closed?
      refute client.closed?
      assert_equal :wait_readable, peer.read_nonblock(100, exception: false)
    end
  end

  def test_empty_write_cannot_report_success_after_conversion_closes_the_session
    session, = writable_session
    object = Object.new
    object.define_singleton_method(:to_s) do
      session.close
      ""
    end
    assert_raises(IOError) { session.write(object) }
  end

  def test_single_and_multiple_object_conversion_preserves_false_nil_and_binary_bytes
    session, sink = writable_session
    conversions = 0
    object = Object.new
    object.define_singleton_method(:to_s) do
      conversions += 1
      "a\xFF".b
    end
    assert_equal 2, session.write(object)
    assert_equal "a\xFF".b, sink.read(2)
    assert_equal 1, conversions
    assert_equal 1, session.write(nil, "x")
    assert_equal "x", sink.read(1)
    assert_equal 5, session.write(false)
    assert_equal "false", sink.read(5)
    assert_equal 0, session.write(nil)
  end

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
