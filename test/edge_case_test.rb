# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class EdgeCaseTest < ExpectTest
  def test_zero_width_continuation_observes_original_deadline
    session, = pipe_session
    session.buffer = "ready"
    result = bounded(1) do
      session.expect(timeout: 0.01) { on(/(?=ready)/) { Expect.continue(reset_timeout: false) } }
    end
    assert result.timeout?
  end

  def test_zero_width_continuation_waits_for_new_input_before_matching_again
    session, = pipe_session
    session.buffer = "ready"
    calls = 0

    result = bounded(1) do
      session.expect(timeout: 0.01) do
        on(/(?=ready)/) do
          calls += 1
          Expect.continue
        end
      end
    end

    assert result.timeout?
    assert_equal 1, calls
  end

  def test_stalled_pattern_can_match_again_after_new_input
    session, writer = pipe_session
    session.buffer = "ready"
    first_match = Queue.new
    background do
      first_match.pop
      writer.write("!")
    end
    calls = 0

    result = bounded(1) do
      session.expect(timeout: 0.5) do
        on(/(?=ready)/) do
          calls += 1
          first_match << true if calls == 1
          calls == 1 ? Expect.continue : nil
        end
      end
    end

    assert result.matched?
    assert_equal 2, calls
    assert_equal "ready!", session.buffer
  end

  def test_stalled_pattern_can_match_again_after_timeout_callback_changes_buffer
    session, = pipe_session
    session.buffer = "ready"
    calls = 0
    timeouts = 0

    result = bounded(1) do
      session.expect(timeout: 0.01) do
        on(/(?=ready)/) do
          calls += 1
          calls == 1 ? Expect.continue : nil
        end
        timeout do
          timeouts += 1
          session.buffer = "ready!"
          timeouts == 1 ? Expect.continue : nil
        end
      end
    end

    assert result.matched?
    assert_equal 2, calls
    assert_equal 1, timeouts
  end

  def test_stdout_works_with_utf8_banner_and_ascii_regexp
    session, writer = pipe_session
    writer.write("欢迎登录\nprompt>")
    assert_equal 1, session.expect(/prompt>/, timeout: 1).number
    assert_equal "欢迎登录\n".b, session.before
  end

  def test_invalid_fixed_encoding_regexp_data_raises
    session, = pipe_session
    session.buffer = "\xffinvalid".b
    assert_raises(EncodingError) { session.expect(/中文/, timeout: 0).number }
  end

  def test_replacing_log_with_invalid_target_preserves_current_log
    session, = pipe_session
    log = StringIO.new
    session.log_to(log)
    assert_raises(ArgumentError) { session.log_to(42) }
    assert_same log, session.log_output
    session.write_log("still open")
    assert_equal "still open", log.string
  end

  def test_new_session_predicates_use_ruby_truthiness
    Expect.configure(raw_pty: 0, log_stdout: nil)
    session = Expect.new
    @sessions << session
    assert session.raw_pty?
    refute session.log_stdout?
  end

  def test_read_only_regular_file
    Tempfile.create("expect-input") do |file|
      file.write("first\nsecond\n")
      file.rewind
      Expect.open(file) do |session|
        assert_equal 1, session.expect(/^second$/, timeout: 0).number
        assert_equal "first\n", session.before
        assert session.expect(:eof, timeout: 1).eof?
      end
      refute file.closed?
    end
  end

  def test_existing_pty_eio_is_eof
    master, slave = PTY.open
    @ios.push(master, slave)
    session = Expect.open(master)
    @sessions << session
    slave.write("end")
    slave.flush
    assert_equal 1, session.expect("end", timeout: 1).number
    slave.close
    assert bounded { session.expect(:eof, timeout: 1) }.eof?
  end

  def test_distinct_reader_writer_io
    incoming, producer = IO.pipe
    consumer, outgoing = IO.pipe
    @ios.push(incoming, producer, consumer, outgoing)
    session = Expect.open(incoming, writer: outgoing)
    @sessions << session
    producer.write("ready")
    assert_equal 1, session.expect("ready", timeout: 1).number
    assert_equal 3, session.write("abc")
    assert_equal "abc", consumer.read(3)
    session.close
    refute incoming.closed?
    refute outgoing.closed?
  end

  def test_control_character_delivers_signal_to_foreground_child
    session = child('Signal.trap("INT") { exit 42 }; puts "ready"; sleep 30')
    assert_equal 1, session.expect("ready", timeout: 2).number
    session.write("\x03")
    assert_equal 42, session.wait(timeout: 2).exitstatus
  end

  def test_multiple_real_pty_processes
    first = child('puts "one"')
    second = child('STDIN.gets; puts "two"', raw_pty: true)
    seen = []
    record_session = lambda do |session|
      seen << session
      Expect.continue(reset_timeout: false)
    end
    result = Expect.expect(timeout: 2) do
      on(/one/, from: first, &record_session)
      eof(from: first) do
        # 明确建立两个进程的顺序，不能通过 sleep 推断启动和输出的先后。
        second.puts("continue")
        Expect.continue(reset_timeout: false)
      end
      on("two", from: second)
    end
    assert_equal [first], seen
    assert_same second, result.session
    assert_equal 3, result.number
  end

  def test_signal_interruption_preserves_deadline
    session, writer = pipe_session
    old_handler = Signal.trap("USR1") { nil }
    background do
      4.times do
        sleep 0.01
        Process.kill("USR1", Process.pid)
      end
      writer.write("ready")
    end
    assert_equal(1, bounded { session.expect("ready", timeout: 1).number })
  ensure
    Signal.trap("USR1", old_handler) if old_handler
  end

  def test_gc_reclaims_abandoned_child
    assert_gc_reclaims_abandoned_child
  end

  def test_gc_reclaims_abandoned_child_with_log_callback_capturing_session
    assert_gc_reclaims_abandoned_child(log_callback: true)
  end

  def test_invalid_options_raise_before_spawning
    assert_raises(ArgumentError) { Expect.new(typo: true) }
    session, = pipe_session
    assert_raises(ArgumentError) { session.expect(0, "x").number }
    assert_raises(ArgumentError) { session.expect(["-unknown", "x"], timeout: 0).number }
    assert_raises(ArgumentError) { session.on_sequence("") }
  end

  def test_entrypoint_can_coexist_with_standard_library_expect
    entrypoint = File.expand_path("../lib/expect/pty.rb", __dir__)
    script = <<~RUBY
      require "rbconfig"
      require File.join(RbConfig::CONFIG.fetch("rubylibdir"), "expect.rb")
      require ARGV.fetch(0)
      puts [IO.method_defined?(:expect), defined?(Expect), Expect::VERSION].join(":")
    RUBY
    environment = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil }
    output, status = Open3.capture2e(environment, RbConfig.ruby, "-e", script, entrypoint)
    assert status.success?, output
    assert_equal "true:constant:#{Expect::VERSION}\n", output
  end

  private

  def assert_gc_reclaims_abandoned_child(log_callback: false)
    script = <<~RUBY
      require "expect"
      require "rbconfig"
      def abandoned
        session = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "sleep 60", log_stdout: false)
        session.log_to { |bytes| [session.pid, bytes] } if #{log_callback}
        session.pid
      end
      # Ruby 的保守 GC 可能扫描到创建线程栈上残留的引用；先结束该线程，确保会话确实不可达。
      pid = Thread.new { abandoned }.value
      20.times do
        GC.start
        sleep 0.02
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          puts "reaped"
          exit 0
        end
      end
      Process.kill("KILL", pid) rescue nil
      Process.waitpid(pid) rescue nil
      abort "abandoned child survived GC"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__), "-e",
                                     script)
    assert status.success?, output
    assert_equal "reaped\n", output
  end
end
