# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class ProcessInterruptionTest < ExpectTest
  def test_hard_close_reaps_a_real_child_after_one_wait_interruption
    session = child('Signal.trap("HUP", "IGNORE"); Signal.trap("TERM", "IGNORE"); puts "ready"; sleep 60',
                    raw_pty: true)
    assert_equal 1, session.expect("ready", timeout: 2).number
    pid = session.pid
    original = Process.method(:waitpid2)
    interrupted = false
    Process.stub(:waitpid2, lambda { |*args|
      if args.first == pid && !interrupted
        interrupted = true
        raise Errno::EINTR
      end
      original.call(*args)
    }) do
      status = bounded { session.hard_close(timeout: 0) }
      assert_instance_of Process::Status, status
      assert_equal Signal.list.fetch("KILL"), status.termsig
      assert_same status, session.process_status
    end
    assert interrupted
    assert_nil session.pid
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    session&.hard_close(timeout: 0)
  end

  def test_continuous_wait_interruptions_keep_the_original_deadline_and_pid
    with_fake_child do |session, resources, calls|
      with_clock(session) do |now|
        Process.stub(:waitpid2, lambda { |*|
          calls << :wait
          raise Errno::EINTR
        }) do
          assert_nil(bounded { session.wait(timeout: 0.03) })
          assert_equal 0.03, now.call
          assert_operator calls.size, :<=, 5
          assert_operator calls.size, :>=, 3
          assert_equal 123_456, resources.pid
          assert_nil resources.status
        end
      end
    end
  end

  def test_continuous_wait_and_signal_interruptions_are_bounded_during_hard_close
    with_fake_child do |session, resources, calls|
      with_clock(session) do |now|
        Process.stub(:waitpid2, lambda { |*|
          calls << :wait
          raise Errno::EINTR
        }) do
          Process.stub(:kill, lambda { |signal, *|
            calls << signal
            raise Errno::EINTR
          }) do
            assert_nil(bounded { session.hard_close(timeout: 0.02) })
            assert_in_delta 1.04, now.call, 0.000001
            assert_operator calls.count("TERM"), :>, 1
            assert_operator calls.count("KILL"), :>, 1
            assert_operator calls.size, :<, 230
            assert_equal 123_456, resources.pid
            assert_nil resources.status
          end
        end
      end
    end
  end

  def test_signal_interruption_retries_without_extending_the_soft_close_budget
    with_fake_child do |session, resources, calls|
      with_clock(session) do |now|
        Process.stub(:kill, lambda { |signal, _pid|
          calls << signal
          raise Errno::EINTR if calls.count(signal) == 1
        }) do
          assert_nil session.soft_close(timeout: 0, term_timeout: 0.03)
          assert_equal 0.03, now.call
          assert_equal %w[TERM TERM], calls.grep(String)
          assert_equal 123_456, resources.pid
          assert_nil resources.status
        end
      end
    end
  end

  def test_echild_clears_ownership_before_any_signal_or_detach
    with_fake_child do |session, resources, calls|
      Process.stub(:waitpid2, ->(*) { raise Errno::ECHILD }) do
        assert_nil session.hard_close(timeout: 0)
        resources.finalize
        assert_nil resources.pid
        assert_nil resources.status
        assert_empty calls
      end
    end
  end

  def test_finalizer_continues_to_kill_and_detach_after_interrupted_reap
    with_fake_child do |_session, resources, calls|
      Process.stub(:waitpid2, lambda { |*|
        calls << :wait
        raise Errno::EINTR
      }) do
        bounded { resources.finalize }
      end
      assert_equal [:wait, "KILL", :detach], calls
      assert_nil resources.pid
      assert_nil resources.status
    end
  end

  def test_finalizer_detaches_even_if_kill_is_continuously_interrupted
    with_fake_child do |session, resources, calls|
      session.log_to { flunk "finalizer invoked a user callback" }
      Process.stub(:kill, lambda { |signal, *|
        calls << signal
        raise Errno::EINTR
      }) do
        bounded { resources.finalize }
      end
      assert_equal :detach, calls.last
      assert_operator calls.count("KILL"), :>=, 1
      assert_operator calls.count("KILL"), :<=, 2
      assert_nil resources.pid
      assert_nil resources.status
    end
  end

  def test_finalizer_retains_unknown_pid_if_detach_also_fails
    with_fake_child do |_session, resources, _calls|
      Process.stub(:detach, ->(*) { raise Errno::EINTR }) { bounded { resources.finalize } }
      assert_equal 123_456, resources.pid
      assert_nil resources.status
    end
  end

  def test_non_owner_never_waits_signals_or_detaches
    with_fake_child do |session, resources, calls|
      Process.stub(:pid, resources.owner + 1) do
        resources.finalize
        assert_nil session.wait(timeout: 0)
        assert_nil session.hard_close(timeout: 0)
      end
      assert_empty calls
      assert_equal 123_456, resources.pid
    end
  end

  def test_forked_copy_cannot_reap_signal_or_detach_the_parent_child
    session = child('puts "ready"; sleep 60', raw_pty: true)
    assert_equal 1, session.expect("ready", timeout: 2).number
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    probe = fork do
      reader.close
      forbidden = ->(*) { raise "non-owner attempted process cleanup" }
      Process.stub(:waitpid2, forbidden) do
        Process.stub(:kill, forbidden) do
          Process.stub(:detach, forbidden) do
            session.__send__(:session).instance_variable_get(:@resources).finalize
            session.hard_close(timeout: 0)
            writer.write("ok")
          end
        end
      end
      exit! 0
    rescue Exception # rubocop:disable Lint/RescueException -- 子进程只回传验证失败，父进程负责回收。
      exit! 1
    end
    writer.close
    assert_equal("ok", bounded { reader.read })
    status = bounded { Process.waitpid2(probe).last }
    probe = nil
    assert status.success?
    assert session.alive?
  ensure
    if probe
      begin
        Process.kill("KILL", probe)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(probe)
      rescue Errno::ECHILD
        nil
      end
    end
    session&.hard_close(timeout: 0)
  end

  def test_finalizer_rechecks_ownership_before_detaching_after_a_signal
    with_fake_child do |_session, resources, calls|
      owner = resources.owner
      Process.stub(:pid, -> { owner }) do
        Process.stub(:kill, lambda { |signal, *|
          calls << signal
          owner += 1
        }) do
          resources.finalize
        end
      end
      assert_equal [:wait, "KILL"], calls
      assert_equal 123_456, resources.pid
      assert_nil resources.status
    end
  end

  def test_esrch_during_signal_still_reaps_without_inventing_status
    with_fake_child do |session, resources, calls|
      gone = false
      Process.stub(:waitpid2, lambda { |*|
        calls << :wait
        raise Errno::ECHILD if gone
      }) do
        Process.stub(:kill, lambda { |signal, *|
          calls << signal
          gone = true
          raise Errno::ESRCH
        }) do
          assert_nil session.hard_close(timeout: 0)
        end
      end
      assert_equal [:wait, :wait, "TERM", :wait], calls
      assert_nil resources.pid
      assert_nil resources.status
    end
  end

  def test_zero_budget_close_returns_status_reaped_after_esrch
    status = child("exit 7").wait(timeout: 2)
    assert_instance_of Process::Status, status
    %i[soft_close hard_close].each do |method|
      with_fake_child do |session, resources, calls|
        gone = false
        Process.stub(:waitpid2, lambda { |pid, *|
          calls << :wait
          [pid, status] if gone
        }) do
          Process.stub(:kill, lambda { |signal, *|
            calls << signal
            gone = true
            raise Errno::ESRCH
          }) do
            options = { timeout: 0 }
            options[:term_timeout] = 0 if method == :soft_close
            assert_same status, session.public_send(method, **options)
          end
        end
        assert_nil resources.pid
        assert_same status, session.process_status
        assert_equal [:wait, :wait, "TERM", :wait], calls
      end
    end
  end

  private

  # 假 PID 只存在于系统调用全部被替换的作用域；ensure 先撤销 PID，再交给通用 teardown。
  def with_fake_child
    session, = pipe_session
    resources = session.__send__(:session).instance_variable_get(:@resources)
    calls = []
    originals = %i[waitpid2 kill detach].to_h { |name| [name, Process.method(name)] }
    Process.define_singleton_method(:waitpid2) do |*|
      calls << :wait
      nil
    end
    Process.define_singleton_method(:kill) do |signal, *|
      calls << signal
      1
    end
    Process.define_singleton_method(:detach) do |*|
      calls << :detach
      nil
    end
    resources.pid = 123_456
    yield session, resources, calls
  ensure
    resources.pid = nil if resources
    originals&.each { |name, method| Process.define_singleton_method(name, method) }
  end

  def with_clock(session)
    now = 0.0
    Expect.stub(:monotonic, -> { now }) do
      session.__send__(:session).stub(:sleep, ->(seconds) { now += seconds }) { yield -> { now } }
    end
  end
end
