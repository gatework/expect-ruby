# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require "stringio"
require "tempfile"
require "tmpdir"
require "socket"
require_relative "../lib/expect"

class ExpectTest < Minitest::Test
  def setup
    @sessions = []
    @ios = []
    @threads = []
    @configuration = Expect.configuration
  end

  def teardown
    @threads.each { |thread| thread.kill.join if thread.alive? }
    @sessions.reverse_each { |session| session.hard_close(timeout: 0.03) }
    @ios.each { |io| io.close unless io.closed? }
    Expect.configure(**@configuration.to_h)
  end

  def child(script, **)
    session = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "STDOUT.sync = true; STDERR.sync = true; #{script}",
                           log_stdout: false, **)
    @sessions << session
    session
  end

  def pipe_session(**)
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    session = Expect.open(reader, **)
    @sessions << session
    [session, writer]
  end

  def background(&)
    @threads << Thread.new(&)
    @threads.last
  end

  def bounded(seconds = 5, &)
    Timeout.timeout(seconds, &)
  end

  def terminal_configuration(session)
    state = session.stty
    return state unless RUBY_PLATFORM.include?("darwin")

    # Darwin marks pending-input retyping after tcsetattr. PENDIN is a kernel
    # state bit (sys/termios.h), not a changed terminal configuration.
    state.sub(/lflag=([0-9a-f]+)/) { "lflag=#{(Regexp.last_match(1).to_i(16) & ~0x20000000).to_s(16)}" }
  end
end
