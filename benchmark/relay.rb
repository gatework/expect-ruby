# frozen_string_literal: true

require_relative "support"

runner = ExpectBenchmark::Runner.new("relay")
reader, writer = IO.pipe
session = Expect.open(reader, log_stdout: false)
begin
  size = runner.smoke ? 4096 : 65_536
  payload = "x" * size
  %i[none literal regexps].each do |kind|
    session.__send__(:sequences=, {})
    session.on_sequence("STOP") if kind == :literal
    16.times { |index| session.on_sequence(/missing#{index}/) } if kind == :regexps
    output = StringIO.new("".b)
    session.listeners = [output]
    verify = ->(result) { ExpectBenchmark.check(result == true && output.string == payload) }
    runner.measure("escape/#{kind}", bytes: size, inputs: { size: size, regexps: kind == :regexps ? 16 : 0 },
                                     verify: verify) do
      output.string = "".b
      session.__send__(:relay_history).clear
      Expect.__send__(:relay_buffer, session, { session => payload.b })
    end
  end

  session.__send__(:sequences=, {})
  writer.close
  normal = StringIO.new("".b)
  slow = StringIO.new("".b)
  slow.define_singleton_method(:write) { |data| super(data.byteslice(0, 17)) }
  session.listeners = [normal, slow]
  verify = lambda do |result|
    ExpectBenchmark.check(result.equal?(session) && normal.string == payload && slow.string == payload)
    ExpectBenchmark.check(!session.pending_output? && session.buffer.empty?)
  end
  runner.measure("mixed_targets", bytes: size * 2, inputs: { size: size, short_write: 17 }, iterations: 5,
                                  verify: verify) do
    normal.string = "".b
    slow.string = "".b
    session.buffer = payload
    Timeout.timeout(10) { Expect.interconnect(session, timeout: 5) }
  end
ensure
  session.close
  reader.close
  writer.close unless writer.closed?
end
runner.finish
