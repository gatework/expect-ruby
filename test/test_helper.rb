# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require "stringio"
require "tempfile"
require "tmpdir"
require "socket"
require_relative "../lib/expect"
require_relative "support/terminal_probe"

class ExpectTest < Minitest::Test
  def setup
    @sessions = []
    @ios = []
    @threads = []
  end

  def teardown
    @threads.each { |thread| thread.kill.join if thread.alive? }
    @sessions.reverse_each { |session| session.hard_close(timeout: 0.03) }
    @ios.each { |io| io.close unless io.closed? }
  end

  def child(script, **)
    session = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e",
                           "STDOUT.sync = true; STDERR.sync = true; #{script}", **)
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
    TerminalProbe.configuration(session.to_io)
  end

  def write_target(&handler)
    Object.new.tap do |target|
      target.define_singleton_method(:write) do |bytes|
        handler.call(bytes)
        bytes.bytesize
      end
    end
  end

  def diagnostic_logger(level: Logger::DEBUG, &handler)
    Logger.new(StringIO.new, level:).tap do |logger|
      if handler
        logger.formatter = lambda do |_severity, _time, _progname, event|
          handler.call(event)
          ""
        end
      end
    end
  end

  private

  # 业务相等不应改变来源的缓冲、匹配进展、EOF 派发和转接所有权。
  def equalize_sessions(*sessions)
    sessions.each do |session|
      session.define_singleton_method(:hash) { 0 }
      session.define_singleton_method(:eql?) { |other| other.is_a?(Expect::Session) }
      session.define_singleton_method(:==) { |other| other.is_a?(Expect::Session) }
    end
  end
end
