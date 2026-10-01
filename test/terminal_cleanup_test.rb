# frozen_string_literal: true

require_relative "test_helper"

class TerminalCleanupTest < ExpectTest
  def test_read_failures_preserve_identity_reap_helper_and_leave_main_session_usable
    [IOError.new("read failed"), Interrupt.new("interrupted"), SystemExit.new(17)].each do |failure|
      session = terminal_session
      main_pid = session.pid
      with_stty_pipe do |reader, sink, spawned|
        reader.stub(:read, -> { raise failure }) do
          assert_same failure, assert_raises(failure.class) { bounded { session.stty } }
        end
        assert reader.closed?
        assert sink.closed?
        assert_reaped spawned.fetch(:pid)
      end
      assert_main_session_usable session, main_pid
    end
  end

  def test_read_error_wins_over_close_error_and_helper_is_still_reaped
    session = terminal_session
    failure = IOError.new("read failed")
    attempts = 0
    with_stty_pipe do |reader, sink, spawned|
      reader.stub(:read, -> { raise failure }) do
        reader.stub(:close, lambda {
          attempts += 1
          raise IOError, "close failed"
        }) do
          assert_same failure, assert_raises(IOError) { bounded { session.stty } }
          refute reader.closed?, "permanently failing close must not be reported as closed"
          assert sink.closed?
          assert_reaped spawned.fetch(:pid)
        end
      end
    end
    assert_equal 1, attempts
  end

  def test_cleanup_error_after_success_is_visible_even_inside_caller_rescue
    session = terminal_session
    failure = IOError.new("close failed")
    begin
      raise ArgumentError, "already handled"
    rescue ArgumentError
      with_stty_pipe do |reader, sink, spawned|
        reader.stub(:close, -> { raise failure }) do
          assert_same failure, assert_raises(IOError) { bounded { session.stty } }
          assert sink.closed?
          assert_reaped spawned.fetch(:pid)
        end
      end
    end
  end

  def test_spawn_failure_attempts_both_closes_and_keeps_missing_command_cause
    session = terminal_session
    reader, sink = IO.pipe
    @ios.push(reader, sink)
    failure = Errno::ENOENT.new("missing stty")
    IO.stub(:pipe, [reader, sink]) do
      Process.stub(:spawn, ->(*) { raise failure }) do
        Process.stub(:kill, ->(*) { flunk "no helper was spawned" }) do
          reader.stub(:close, -> { raise IOError, "reader close failed" }) do
            error = assert_raises(IOError) { session.stty }
            assert_match "stty executable not found", error.message
            assert_same failure, error.cause
            assert sink.closed?
          end
        end
      end
    end
  end

  def test_externally_reaped_helper_is_not_signalled_and_does_not_change_main_status
    session = terminal_session
    main_pid = session.pid
    failure = IOError.new("read failed after external wait")
    with_stty_pipe do |reader, _sink, spawned|
      reader.stub(:read, lambda {
        bounded { Process.waitpid2(spawned.fetch(:pid)) }
        raise failure
      }) do
        Process.stub(:kill, ->(*) { flunk "must not signal an externally reaped PID" }) do
          assert_same failure, assert_raises(IOError) { bounded { session.stty } }
        end
      end
      assert_reaped spawned.fetch(:pid)
    end
    assert_main_session_usable session, main_pid
  end

  def test_uncooperative_helper_is_killed_and_reaped_after_read_failure
    session = terminal_session
    failure = IOError.new("read failed")
    command = [RbConfig.ruby, "--disable-gems", "-e",
               'Signal.trap("TERM", "IGNORE"); STDOUT.sync = true; puts "ready"; sleep 60']
    signals = []
    kill = Process.method(:kill)
    with_stty_pipe(command:) do |reader, _sink, spawned|
      read = reader.method(:gets)
      reader.stub(:read, lambda {
        assert_equal("ready\n", bounded { read.call })
        raise failure
      }) do
        Process.stub(:kill, lambda { |signal, pid|
          signals << [signal, pid]
          kill.call(signal, pid)
        }) do
          assert_same failure, assert_raises(IOError) { bounded(2) { session.stty } }
        end
      end
      assert_equal [["TERM", spawned.fetch(:pid)], ["KILL", spawned.fetch(:pid)]], signals
      assert_reaped spawned.fetch(:pid)
    end
  end

  def test_normal_wait_retries_eintr_without_signalling_or_sleeping
    session = terminal_session
    wait = Process.method(:waitpid2)
    attempts = 0
    with_stty_pipe do |_reader, _sink, spawned|
      Process.stub(:waitpid2, lambda { |pid, *flags|
        assert_equal spawned.fetch(:pid), pid
        attempts += 1
        raise Errno::EINTR if attempts == 1

        wait.call(pid, *flags)
      }) do
        session.__send__(:session).stub(:sleep, ->(*) { flunk "successful stty must not add a fixed delay" }) do
          Process.stub(:kill, ->(*) { flunk "successful helper must not be signalled" }) do
            refute_empty session.stty
          end
        end
      end
      assert_equal 2, attempts
      assert_reaped spawned.fetch(:pid)
    end
  end

  def test_continuous_cleanup_eintr_has_a_fixed_budget_and_detaches_real_helper
    session = terminal_session
    failure = IOError.new("read failed")
    clock = 0.0
    waiter = nil
    detach = Process.method(:detach)
    attempts = 0
    with_stty_pipe do |reader, _sink, spawned|
      reader.stub(:read, -> { raise failure }) do
        Expect.stub(:monotonic, -> { clock }) do
          session.__send__(:session).stub(:sleep, ->(duration) { clock += duration }) do
            Process.stub(:waitpid2, lambda { |pid, flags|
              assert_equal spawned.fetch(:pid), pid
              assert_equal Process::WNOHANG, flags
              attempts += 1
              raise Errno::EINTR
            }) do
              Process.stub(:kill, ->(*) { flunk "ownership has not been checked successfully" }) do
                Process.stub(:detach, lambda { |pid|
                  assert_equal spawned.fetch(:pid), pid
                  waiter = detach.call(pid)
                }) do
                  assert_same failure, assert_raises(IOError) { bounded { session.stty } }
                end
              end
            end
          end
        end
      end
      assert_operator attempts, :>, 3
      assert_in_delta 0.15, clock, 0.000001
      refute_nil waiter
      assert_instance_of(Process::Status, bounded { waiter.value })
      assert_reaped spawned.fetch(:pid)
    end
  end

  def test_esrch_between_poll_and_signal_still_reaps_without_fabricating_status
    session = terminal_session
    main_pid = session.pid
    failure = IOError.new("read failed")
    clock = 0.0
    signalled = false
    wait = Process.method(:waitpid2)
    with_stty_pipe do |reader, _sink, spawned|
      reader.stub(:read, -> { raise failure }) do
        Expect.stub(:monotonic, -> { clock }) do
          session.__send__(:session).stub(:sleep, ->(duration) { clock += duration }) do
            Process.stub(:waitpid2, lambda { |pid, flags|
              assert_equal Process::WNOHANG, flags
              signalled ? wait.call(pid, flags) : nil
            }) do
              Process.stub(:kill, lambda { |signal, pid|
                assert_equal "TERM", signal
                assert_equal spawned.fetch(:pid), pid
                bounded { wait.call(pid) }
                signalled = true
                raise Errno::ESRCH
              }) do
                Process.stub(:detach, ->(*) { flunk "ECHILD already released ownership" }) do
                  assert_same failure, assert_raises(IOError) { bounded { session.stty } }
                end
              end
            end
          end
        end
      end
      assert signalled
      assert_reaped spawned.fetch(:pid)
    end
    assert_main_session_usable session, main_pid
  end

  def test_sink_close_failure_still_attempts_reader_close_and_reaps_helper
    session = terminal_session
    failure = IOError.new("sink close failed")
    attempts = 0
    with_stty_pipe do |reader, sink, spawned|
      sink.stub(:close, lambda {
        attempts += 1
        raise failure
      }) do
        assert_same failure, assert_raises(IOError) { bounded { session.stty } }
        assert reader.closed?
        refute sink.closed?
        assert_reaped spawned.fetch(:pid)
      end
    end
    assert_equal 2, attempts
  end

  def test_forked_copy_closes_local_pipes_without_reaping_or_signalling_parent_helper
    session = terminal_session
    current_pid = Process.pid
    failure = IOError.new("unwind in forked copy")
    with_stty_pipe do |reader, sink, _spawned|
      Process.stub(:pid, -> { current_pid }) do
        reader.stub(:read, lambda {
          current_pid = -1 # 在资源登记后模拟 fork 子进程的身份，父进程仍拥有辅助 PID。
          raise failure
        }) do
          Process.stub(:waitpid2, ->(*) { flunk "non-owner must not wait for the parent's helper" }) do
            Process.stub(:kill, ->(*) { flunk "non-owner must not signal the parent's helper" }) do
              Process.stub(:detach, ->(*) { flunk "non-owner must not detach the parent's helper" }) do
                assert_same failure, assert_raises(IOError) { session.stty }
                assert reader.closed?
                assert sink.closed?
              end
            end
          end
        end
      end
    end
  end

  def test_ledger_initialization_failure_still_closes_both_pipes
    session = terminal_session
    [IOError.new("ledger failed"), Interrupt.new("interrupted registration")].each do |failure|
      with_stty_pipe do |reader, sink, spawned|
        Expect::SessionResources.stub(:new, ->(*) { raise failure }) do
          assert_same failure, assert_raises(failure.class) { session.stty }
          assert reader.closed?
          assert sink.closed?
          assert_empty spawned
        end
      end
    end
  end

  def test_fork_during_cleanup_wait_stops_process_cleanup
    session = terminal_session
    current_pid = Process.pid
    failure = IOError.new("read failed")
    with_stty_pipe do |reader, sink, _spawned|
      Process.stub(:pid, -> { current_pid }) do
        reader.stub(:read, -> { raise failure }) do
          session.__send__(:session).stub(:sleep, ->(*) { current_pid = -1 }) do
            Process.stub(:waitpid2, ->(*) {}) do
              Process.stub(:kill, ->(*) { flunk "fork during wait must release inherited process ownership" }) do
                Process.stub(:detach, ->(*) { flunk "non-owner must not detach" }) do
                  assert_same failure, assert_raises(IOError) { bounded { session.stty } }
                  assert reader.closed?
                  assert sink.closed?
                end
              end
            end
          end
        end
      end
    end
  end

  private

  def terminal_session
    session = child(<<~'RUBY', raw_pty: true)
      puts "ready"
      while (line = STDIN.gets)
        puts "reply:#{line.strip}"
      end
    RUBY
    assert_equal 1, session.expect("ready", timeout: 2).number
    session
  end

  def assert_main_session_usable(session, main_pid)
    assert_equal main_pid, session.pid
    assert_nil session.process_status
    refute session.closed?
    session.puts "still usable"
    assert_equal 1, session.expect("reply:still usable", timeout: 2).number
  end

  def assert_reaped(pid)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  # 只替换本次 stty 的管道；即使断言失败，恢复全局 stub 后仍由探针回收自己的真实子进程。
  def with_stty_pipe(command: nil)
    reader, sink = IO.pipe
    @ios.push(reader, sink)
    spawned = {}
    spawn = Process.method(:spawn)
    IO.stub(:pipe, [reader, sink]) do
      Process.stub(:spawn, lambda { |*arguments, **options|
        spawned[:pid] = spawn.call(*(command || arguments), **options)
      }) do
        yield reader, sink, spawned
      end
    end
  ensure
    reap_probe_child(spawned[:pid]) if spawned && spawned[:pid]
  end

  def reap_probe_child(pid)
    return if Process.waitpid(pid, Process::WNOHANG)

    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    bounded { Process.waitpid(pid) }
  rescue Errno::ECHILD
    nil
  end
end
