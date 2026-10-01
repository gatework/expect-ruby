# frozen_string_literal: true

require_relative "test_helper"

class ProcessTest < ExpectTest
  def test_spawn_has_controlling_terminal_and_merged_stderr
    session = child(<<~RUBY)
      terminal = File.open("/dev/tty", &:tty?)
      puts [STDIN.tty?, STDOUT.tty?, STDERR.tty?, terminal].join(":")
      STDERR.puts "error-stream"
    RUBY
    assert_equal 1, session.expect("true:true:true:true", timeout: 2).number
    assert_equal 1, session.expect("error-stream", timeout: 2).number
    session.soft_close(timeout: 1)
    assert_equal 0, session.exit_code
    assert_equal 0, session.process_status.to_i
    assert session.closed?
    refute session.alive?
  end

  def test_raw_mode_is_applied_before_child_starts
    session = child(<<~'RUBY', raw: true)
      print "name: "
      value = STDIN.gets
      puts "reply=#{value.strip.reverse}"
    RUBY
    session.expect("name: ", timeout: 2)
    session.write("crate\n")
    assert_equal 1, session.expect("reply=etarc\n", timeout: 2).number
    assert_equal "", session.before
  end

  def test_new_pty_supports_slave_configuration_before_spawn
    session = Expect::Session.new
    @sessions << session
    assert session.slave.tty?
    session.slave.echo = false
    session.slave.winsize = [37, 111]
    # 子进程需要 io-console gem，保留 RubyGems 以使用 Bundler 选定的版本。
    session.spawn(RbConfig.ruby, "-rio/console", "-e",
                  'STDOUT.sync = true; puts STDIN.winsize.join(":"); puts STDIN.gets')
    assert_equal 1, session.expect("37:111", timeout: 2).number, session.before.inspect
    assert_equal [37, 111], session.to_io.winsize
    session.to_io.winsize = [24, 80]
    assert_equal [24, 80], session.to_io.winsize
    session.clear_buffer
    session.write("line\n")
    session.expect("line", timeout: 2)
    session.expect(timeout: 2)
    assert_equal "\r\n", session.before
  end

  def test_command_arguments_environment_and_directory
    Dir.mktmpdir do |dir|
      session = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e",
                             'puts ARGV.first; puts ENV.fetch("EXPECT_TEST_VALUE"); puts Dir.pwd', "a;$(exit) b",
                             env: { "EXPECT_TEST_VALUE" => "environment" }, chdir: dir,
                             raw: true)
      @sessions << session
      assert_equal 1, session.expect("a;$(exit) b\nenvironment\n#{File.realpath(dir)}\n", timeout: 2).number
    end
  end

  def test_string_command_supports_shell_semantics
    session = Expect.spawn("printf 'shell-one'; printf 'shell-two'")
    @sessions << session
    assert_equal 1, session.expect("shell-oneshell-two", timeout: 2).number
  end

  def test_exec_failure_is_synchronous_and_reaped
    session = Expect::Session.new
    @sessions << session
    error = assert_raises(Expect::SpawnError) { session.spawn("/no/such/expect-test-command") }
    assert_match(/ENOENT/, error.message)
    assert session.closed?
    assert_nil session.pid
    assert_raises(Expect::SpawnError) { session.spawn("cat") }
  end

  def test_spawn_cleans_child_when_post_exec_diagnostics_fail
    inherited_constructor = !Expect::Session.singleton_methods(false).include?(:new)
    failure = IOError.new("spawn diagnostic failed")
    session = Expect::Session.new(logger: diagnostic_logger { raise failure })
    @sessions << session
    Expect::Session.stub(:new, session) do
      assert_same failure, assert_raises(IOError) { Expect.spawn(RbConfig.ruby, "-e", "sleep 60") }
    end
    assert session.closed?
    assert_nil session.pid
    assert_instance_of Process::Status, session.process_status
  ensure
    # Minitest 恢复继承方法时会留下单例代理，测试应还原原本的 Class#new 查找链。
    if inherited_constructor && Expect::Session.singleton_methods(false).include?(:new)
      Expect::Session.singleton_class.remove_method(:new)
    end
  end

  def test_block_closes_child_on_exception
    pid = nil
    assert_raises(RuntimeError) do
      Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "sleep 60") do |session|
        pid = session.pid
        raise "stop"
      end
    end
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_soft_close_drains_output_before_exit_and_returns_process_status
    session = child('sleep 0.03; print "last output"; exit 7', raw: true)
    log = StringIO.new
    session.transcript = log
    assert_equal 7, session.soft_close(timeout: 1).exitstatus
    assert_equal "last output", log.string
    assert_equal "last output", session.buffer
    assert_equal 7, session.exit_code
    refute log.closed?
  end

  def test_hard_close_escalates_uncooperative_child_and_reaps
    session = child('Signal.trap("HUP", "IGNORE"); Signal.trap("TERM", "IGNORE"); puts "ready"; loop { sleep 1 }')
    session.expect("ready", timeout: 2)
    pid = session.pid
    bounded(2) { session.hard_close(timeout: 0.03) }
    assert_equal Signal.list.fetch("KILL"), session.process_status.termsig
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    assert_equal session.process_status, session.hard_close
  end

  def test_soft_close_sends_term_and_returns_the_exit_status
    session = child(<<~RUBY, raw: true)
      Signal.trap("HUP", "IGNORE")
      Signal.trap("TERM") { exit 7 }
      puts "ready"
      sleep 60
    RUBY
    session.expect("ready", timeout: 2)
    status = bounded { session.soft_close(timeout: 0, term_timeout: 1) }
    assert_equal 7, status.exitstatus
    assert session.closed?
    refute session.alive?
    assert_same status, session.soft_close(timeout: 0)
  end

  def test_soft_close_never_sends_kill_and_retains_a_live_pid_for_hard_close
    session = child(<<~RUBY)
      Signal.trap("HUP", "IGNORE")
      Signal.trap("TERM", "IGNORE")
      puts "ready"
      sleep 60
    RUBY
    session.expect("ready", timeout: 2)
    pid = session.pid
    assert_nil(bounded { session.soft_close(timeout: 0, term_timeout: 0.03) })
    assert session.closed?
    assert session.alive?
    assert_equal pid, session.pid
    assert_nil session.wait(timeout: 0)
    status = bounded { session.hard_close(timeout: 0.03) }
    assert_equal Signal.list.fetch("KILL"), status.termsig
    assert_nil session.pid
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_block_cleanup_uses_the_explicit_graceful_option_and_drains_output
    log = StringIO.new
    connection = nil
    value = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", 'sleep 0.03; puts "tail"',
                         raw: true, graceful: true) do |session|
      connection = session
      session.transcript = log
      :finished
    end
    assert_equal :finished, value
    assert_equal "tail\n", log.string
    assert connection.closed?
    assert_equal 0, connection.exit_code
    refute log.closed?
  end

  def test_explicit_graceful_close_returns_nil_like_io_close
    session = child('sleep 0.03; print "tail"', raw: true)
    assert_nil session.close(graceful: true)
    assert_equal "tail", session.buffer
    assert_equal 0, session.exit_code
    assert_nil session.close
  end

  def test_close_still_reaps_the_child_when_graceful_logging_fails
    session = child('puts "ready"; sleep 60', raw: true)
    pid = session.pid
    session.transcript = write_target { raise IOError, "transcript failed" }
    assert_raises(IOError) { bounded { session.close(graceful: true) } }
    assert session.closed?
    refute session.alive?
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_invalid_close_timeout_does_not_close_or_signal_the_child
    session = child('puts "ready"; sleep 60')
    session.expect("ready", timeout: 2)
    assert_raises(ArgumentError) { session.soft_close(timeout: 0, term_timeout: nil) }
    assert_raises(ArgumentError) { session.soft_close(timeout: 0, term_timeout: -1) }
    assert_raises(ArgumentError) { session.hard_close(timeout: nil) }
    refute session.closed?
    assert session.alive?
  end

  def test_eof_does_not_prevent_buffered_match
    session = child('print "final"; exit 4', raw: true)
    assert_equal 1, session.expect("final", timeout: 2).number
    assert session.expect(:eof, timeout: 2).eof?
    assert_equal 4, session.wait(timeout: 1).exitstatus
  end

  def test_wait_timeout_and_explicit_close
    session = child("sleep 0.15; exit 0")
    assert_nil session.wait(timeout: 0)
    assert session.alive?
    assert_equal 0, session.wait(timeout: 1).exitstatus
    refute session.alive?
    session.close
    assert_raises(IOError) { session.write("x") }
  end

  def test_borrowed_and_owned_io_lifetimes
    session, writer = pipe_session
    reader = session.to_io
    session.close
    refute reader.closed?
    writer.write("x")
    assert_equal "x", reader.read(1)
    owned = Expect.open(reader, own: true)
    owned.close
    assert reader.closed?
  end

  def test_session_settings_are_independent
    session = Expect::Session.new(timeout: 0.01)
    other = Expect::Session.new
    @sessions.push(session, other)
    assert_equal 0.01, session.timeout
    assert_nil other.timeout
    session.buffer_limit = 30
    assert_equal 30, session.buffer_limit
    assert_nil other.buffer_limit
    assert_match(/\A#<Expect::Session .*closed=false>\z/, session.inspect)
  end
end
