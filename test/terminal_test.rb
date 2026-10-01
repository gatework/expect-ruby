# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class TerminalTest < ExpectTest
  def test_native_mode_roundtrip_preserves_terminal_configuration
    session = terminal_session
    io = session.to_io
    original = terminal_configuration(session)
    saved = io.console_mode

    io.raw!
    io.echo = false
    refute io.echo?
    refute_equal original, terminal_configuration(session)

    io.console_mode = saved
    assert_equal original, terminal_configuration(session)
  end

  def test_native_terminal_operations_do_not_require_a_system_command
    path = ENV.fetch("PATH", nil)
    session = terminal_session
    io = session.to_io
    saved = io.console_mode
    original_echo = io.echo?
    ENV["PATH"] = ""

    Process.stub(:spawn, ->(*) { flunk "native console configuration must not spawn a process" }) do
      io.raw!
      io.echo = false
      refute io.echo?
      io.console_mode = saved
      assert_equal original_echo, io.echo?
    end
  ensure
    ENV["PATH"] = path
  end

  def test_native_window_size_and_mode_changes_leave_borrowed_io_open
    session = terminal_session
    io = session.to_io
    saved = io.console_mode

    io.winsize = [37, 111]
    assert_equal [37, 111], io.winsize
    io.raw!
    io.console_mode = saved
    session.close

    refute io.closed?
    assert_equal [37, 111], io.winsize
  end

  def test_native_console_preserves_errors_for_non_terminal_and_closed_io
    session, = pipe_session
    assert_raises(Errno::ENOTTY) { session.to_io.console_mode }
    session.to_io.close
    assert_raises(IOError) { session.to_io.console_mode }
  end

  private

  def terminal_session
    master, slave = PTY.open
    @ios.push(master, slave)
    Expect.open(slave).tap { |session| @sessions << session }
  end
end
