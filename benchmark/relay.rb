# frozen_string_literal: true

require_relative "support"

counts = [1, 16, 64]
runner = ExpectBenchmark::Runner.new("relay") do |options|
  options.on("--sessions N", Integer, "Measure one explicit session count (check the process fd limit)") do |count|
    raise ArgumentError, "sessions must be positive" unless count.positive?

    counts = [count]
  end
end
reader, writer = IO.pipe
session = Expect.open(reader)
begin
  size = runner.smoke ? 4096 : 65_536
  payload = "x" * size
  writer.close
  %i[none literal regexps].each do |kind|
    session.__send__(:sequences=, {})
    session.on_sequence("STOP") if kind == :literal
    16.times { |index| session.on_sequence(/missing#{index}/) } if kind == :regexps
    output = StringIO.new("".b)
    session.outputs = [output]
    verify = ->(result) { ExpectBenchmark.check(result.equal?(session) && output.string == payload) }
    runner.measure("escape/#{kind}", bytes: size, inputs: { size:, regexps: kind == :regexps ? 16 : 0 },
                                     verify:) do
      output.string = "".b
      session.__send__(:relay_history).clear
      session.buffer = payload
      Timeout.timeout(10) { Expect.interconnect(session, timeout: 5) }
    end
  end

  session.__send__(:sequences=, {})
  buffered_output = StringIO.new("".b)
  session.outputs = [buffered_output]
  (runner.smoke ? [65_536] : [1_048_576, 4_194_304, 16_777_216]).each do |bytes|
    buffered_payload = "x" * bytes
    verify = lambda do |result|
      ExpectBenchmark.check(result.equal?(session) && buffered_output.string == buffered_payload)
      ExpectBenchmark.check(session.buffer.empty? && !session.pending_output?)
    end
    runner.measure("prebuffered/#{bytes}", bytes:, inputs: { size: bytes, escapes: 0 }, verify:, iterations: 1) do
      buffered_output.string = "".b
      session.buffer = buffered_payload
      Timeout.timeout(10) { Expect.interconnect(session, timeout: 5) }
    end
  end

  normal = StringIO.new("".b)
  slow = StringIO.new("".b)
  slow.define_singleton_method(:write) { |data| super(data.byteslice(0, 17)) }
  session.outputs = [normal, slow]
  verify = lambda do |result|
    ExpectBenchmark.check(result.equal?(session) && normal.string == payload && slow.string == payload)
    ExpectBenchmark.check(!session.pending_output? && session.buffer.empty?)
  end
  runner.measure("mixed_targets", bytes: size * 2, inputs: { size:, short_write: 17 }, iterations: 5,
                                  verify:) do
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

# 真实来源集中就绪与只有末个来源就绪，分别检验批量调度与稀疏轮询。
(runner.smoke ? [1, 8] : counts).each do |count|
  if (count * 2) + 32 > Process.getrlimit(:NOFILE).first
    raise ArgumentError, "#{count} sessions need a larger process fd limit; run ulimit -n before this benchmark"
  end

  pipes = []
  sessions = []
  begin
    outputs = Array.new(count) { StringIO.new("".b) }
    count.times do |index|
      pipes << IO.pipe
      source = Expect.open(pipes.last.first)
      source.outputs = [outputs[index]]
      sessions << source
    end
    %i[all last].each do |ready|
      ready_indexes = ready == :all ? (0...count).to_a : [count - 1]
      expected = Array.new(count) { |index| ready_indexes.include?(index) ? "ready" : "" }
      verify = lambda do |result|
        ExpectBenchmark.check(result.nil? && outputs.map(&:string) == expected)
        ExpectBenchmark.check(sessions.none?(&:pending_output?) && sessions.all? { |source| source.buffer.empty? })
      end
      runner.measure("sources/#{ready}/#{count}", bytes: ready_indexes.size * 5,
                                                  inputs: { sessions: count, ready: ready_indexes.size }, verify:) do
        outputs.each { |output| output.string = "".b }
        ready_indexes.each { |index| pipes[index].last.write("ready") }
        Expect.interconnect(*sessions, timeout: 0)
      end
    end
  ensure
    sessions.each(&:close)
    pipes.flatten.each { |io| io.close unless io.closed? }
  end
end
runner.finish
