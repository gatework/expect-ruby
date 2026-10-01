# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class OwnershipSequenceTest < ExpectTest
  SEEDS = [20_260_927, 1, 42].freeze

  def test_failed_initialization_then_failed_cleanup_preserves_ownership_and_primary_error
    SEEDS.each do |seed|
      [true, false].each do |own|
        reader, writer = IO.pipe
        @ios.push(reader, writer)
        attempts = []
        failure = seed.odd? ? Interrupt.new : SystemExit.new(17)
        original = writer.method(:close)
        Expect::SessionResources.stub(:new, ->(*, **) { raise failure }) do
          reader.stub(:close, lambda {
            attempts << :reader
            raise IOError, "injected close failure"
          }) do
            writer.stub(:close, lambda {
              attempts << :writer
              original.call
            }) do
              error = assert_raises(failure.class) { Expect.open(reader, writer:, own:) }
              assert_same failure, error, "seed=#{seed} own=#{own}"
            end
          end
        end
        assert_equal(own ? %i[reader writer] : [], attempts, "seed=#{seed} own=#{own}")
        assert_equal own, writer.closed?
        refute reader.closed?
      end
    end
  end

  def test_short_write_eintr_timeout_and_listener_replacement_keep_per_target_progress
    SEEDS.each do |seed|
      source, = pipe_session
      sink, target_writer = IO.pipe
      @ios.push(sink, target_writer)
      target, = pipe_session(writer: target_writer, write_timeout: 0.01)
      first = StringIO.new
      replacement = StringIO.new
      payload = Random.new(seed).bytes(9)
      source.listeners = [first, target]
      source.buffer = payload
      accepted = 2
      attempts = 0
      now = 0.0
      original = target_writer.method(:write_nonblock)
      Expect.stub(:monotonic, -> { now }) do
        target_writer.stub(:write_nonblock, lambda { |bytes, **options|
          attempts += 1
          case attempts
          when 1 then original.call(bytes.byteslice(0, accepted), **options)
          when 2 then raise Errno::EINTR
          else
            now = 0.02
            :wait_writable
          end
        }) do
          error = assert_raises(Expect::WriteTimeout) { bounded { Expect.interconnect(source, timeout: 1) } }
          assert_equal accepted, error.bytes_written, "seed=#{seed} attempts=#{attempts}"
        end
      end
      prefix = bounded { sink.read(accepted) }
      assert_equal payload.byteslice(0, accepted), prefix, "seed=#{seed} confirmed=#{accepted}"
      assert_equal payload, first.string.b, "seed=#{seed} first target"
      assert_empty source.buffer
      assert source.pending_output?
      source.listeners = [replacement]
      source.buffer = "new"
      Expect.interconnect(source, timeout: 0)
      suffix = bounded { sink.read(payload.bytesize - accepted) }
      assert_equal payload, prefix + suffix, "seed=#{seed} resumed target"
      assert_equal payload, first.string.b, "seed=#{seed} first target replay"
      assert_equal "new", replacement.string, "seed=#{seed} replacement target"
      refute source.pending_output?
      assert_empty source.buffer
    end
  end

  def test_escape_delivery_nested_match_and_resume_account_for_all_source_bytes_once
    SEEDS.each do |seed|
      source, producer = pipe_session
      prefix = "prefix-#{seed}\0".b
      payload = "#{prefix}!consumetail".b
      log = StringIO.new
      sink = StringIO.new
      source.log_to(log)
      source.listeners = [sink]
      calls = 0
      source.on_sequence("!") do
        calls += 1
        assert_equal prefix, sink.string.b, "seed=#{seed} prefix not delivered"
        assert_equal "consume", source.expect("consume", timeout: 0).match
        false
      end
      producer.write(payload)
      assert_same(source, bounded { Expect.interconnect(source, timeout: 1) })
      assert_equal "tail", source.buffer
      assert_equal 1, calls
      assert_equal payload.bytesize, prefix.bytesize + 1 + "consume".bytesize + source.buffer.bytesize
      Expect.interconnect(source, timeout: 0)
      assert_equal "#{prefix}tail", sink.string.b, "seed=#{seed} delivered bytes"
      assert_equal payload, log.string.b, "seed=#{seed} received log replay"
      assert_equal 1, calls
      refute source.pending_output?
      assert_empty source.buffer
    end
  end

  def test_refused_recursion_then_sequential_relay_preserves_bytes_and_releases_ownership
    SEEDS.each do |seed|
      source, = pipe_session
      payload = Random.new(seed).bytes(7)
      sink = StringIO.new
      original = sink.method(:write)
      errors = []
      sink.define_singleton_method(:write) do |bytes|
        count = original.call(bytes)
        begin
          Expect.interconnect(source, timeout: 0)
        rescue Expect::ReentrancyError => error
          errors << error
        end
        count
      end
      source.listeners = [sink]
      2.times do |index|
        source.buffer = payload
        Expect.interconnect(source, timeout: 0)
        assert_equal payload * (index + 1), sink.string.b, "seed=#{seed} iteration=#{index}"
        assert_equal index + 1, errors.size
        assert_empty source.buffer
        refute source.pending_output?
      end
    end
  end

  def test_eof_soft_close_hard_close_and_repeated_status_queries
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    session = Expect.open(reader, own: true)
    @sessions << session
    script = <<~RUBY
      Signal.trap("HUP", "IGNORE")
      Signal.trap("TERM", "IGNORE")
      STDOUT.sync = true
      print "tail"
      STDOUT.reopen(File::NULL, "w")
      sleep 60
    RUBY
    pid = Process.spawn(RbConfig.ruby, "--disable-gems", "-e", script, in: File::NULL, out: writer, err: File::NULL)
    session.__send__(:session).instance_variable_get(:@resources).pid = pid
    writer.close
    result = session.expect(:eof, timeout: 2)
    assert result.eof?
    assert_equal "tail", result.before
    assert session.alive?
    refute session.closed?
    signals = []
    original = Process.method(:kill)
    Process.stub(:kill, lambda { |signal, child_pid|
      signals << signal
      original.call(signal, child_pid)
    }) do
      assert_nil session.soft_close(timeout: 0, term_timeout: 0)
    end
    assert_equal ["TERM"], signals
    assert session.closed?
    assert session.alive?
    status = bounded { session.hard_close(timeout: 0) }
    assert_equal Signal.list.fetch("KILL"), status.termsig
    3.times { assert_same status, session.process_status }
    assert_nil session.pid
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_expired_deadline_dispatches_known_eof_in_order_without_consuming_new_text
    SEEDS.each do |seed|
      ended = Array.new(2) { pipe_session.first }
      ended.each(&:close)
      ended.shuffle!(random: Random.new(seed))
      live, producer = pipe_session
      live.buffer = "buffered"
      producer.write("unread")
      seen = []
      Expect.stub(:monotonic, 1.0) do
        result = Expect.expect(from: [*ended, live], deadline: 1.0) do
          on("buffered") { flunk "seed=#{seed} consumed text after deadline" }
          eof do |session|
            seen << session
            Expect.continue(reset_timeout: seed.odd?)
          end
        end
        assert result.timeout?
      end
      assert_equal ended, seen, "seed=#{seed} EOF order"
      assert_equal "buffered", live.buffer
      assert_equal "unread", live.to_io.read_nonblock(6)
    end
  end
end
