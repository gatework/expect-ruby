# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class BufferRetentionTest < ExpectTest
  def test_assigning_large_input_retains_only_the_configured_buffer
    assert_bounded_storage(
      setup: "session = Expect.open(reader, buffer_limit: 4096)",
      operation: 'session.buffer = "x" * 8_388_608',
      verify: 'session.buffer == "x" * 4096 && session.buffer_discarded_bytes == 8_384_512'
    )
  end

  def test_reducing_the_limit_releases_discarded_storage
    assert_bounded_storage(
      setup: "session = Expect.open(reader)",
      operation: "session.buffer = 'x' * 8_388_608; session.buffer_limit = 4096",
      verify: 'session.buffer == "x" * 4096 && session.buffer_discarded_bytes == 8_384_512'
    )
  end

  def test_timeout_history_does_not_retain_the_entire_forwarded_prefix
    assert_bounded_storage(
      setup: <<~RUBY,
        session = Expect.open(reader)
        session.on_sequence(/NEVER/)
        session.on_sequence("x" * 8_388_608 + "!")
      RUBY
      operation: <<~RUBY,
        session.buffer = "x" * 8_388_608
        Expect.interconnect(session, timeout: 0)
      RUBY
      verify: 'session.buffer.empty? && session.relay_history == "x" * 65_536'
    )
  end

  def test_small_pending_relay_writes_release_the_large_original_buffer
    [false, true].each do |escape|
      assert_bounded_storage(
        setup: <<~RUBY,
          session = Expect.open(reader)
          session.on_sequence("!") if #{escape}
          sent = 0
          failed = false
          output = Object.new
          output.define_singleton_method(:write) do |bytes|
            if sent == 8_372_224 && !failed
              failed = true
              raise IOError, "delivery interrupted"
            end
            sent += bytes.bytesize
            bytes.bytesize
          end
          session.outputs = [output]
        RUBY
        operation: <<~RUBY,
          session.buffer = "x" * 8_388_608 + (#{escape} ? "!" : "")
          begin
            Expect.interconnect(session, timeout: 5)
            abort "expected interrupted delivery"
          rescue IOError
          end
        RUBY
        verify: <<~RUBY
          begin
            abort "missing pending delivery" unless session.pending_output? && session.buffer.empty?
            Expect.interconnect(session, timeout: 0)
            sent == 8_388_608 && !session.pending_output?
          end
        RUBY
      )
    end
  end

  private

  def assert_bounded_storage(setup:, operation:, verify:)
    program = <<~RUBY
      require "expect/pty"
      require "objspace"
      reader, writer = IO.pipe
      #{setup}
      GC.start
      before = ObjectSpace.memsize_of_all(String)
      #{operation}
      GC.start
      retained = ObjectSpace.memsize_of_all(String) - before
      abort "discarded storage retained: \#{retained} bytes" if retained > 1_048_576
      abort "incorrect retained bytes or accounting" unless #{verify}
      session.close
      reader.close
      writer.close
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", program)
    assert status.success?, output
  end
end
