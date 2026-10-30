# frozen_string_literal: true

require_relative "support"

runner = ExpectBenchmark::Runner.new("matching")
# 只在校验时适配旧基线的字段名，计时内仍运行同一匹配算法。
number_reader = Expect.const_get(:Pattern).members.include?(:match_number) ? :match_number : :number
reader, writer = IO.pipe
session = Expect.open(reader)
begin
  sizes = runner.smoke ? [4096] : [4096, 65_536, 1_048_576]
  sizes.product([1, 8, 32], %i[first last miss]).each do |size, count, hit|
    session.buffer = "#{"x" * (size - 3)}END"
    patterns = Array.new(count) { |index| /missing#{index}/ }
    index = hit == :first ? 0 : count - 1
    patterns[index] = /END/ unless hit == :miss
    matcher = Expect.const_get(:Matcher, false).new(Expect::PatternList.new([session], patterns), 0)
    verify = lambda do |result|
      valid = if hit == :miss
                result.nil?
              else
                result && result[0].equal?(session) && result[1].public_send(number_reader) == index + 1 &&
                  result[2] == [size - 3, 3, []]
              end
      ExpectBenchmark.check(valid)
    end
    runner.measure("scan/#{size}/#{count}/#{hit}", bytes: size, inputs: { size:, patterns: count, hit: },
                                                   verify:) { matcher.__send__(:find_match) }
  end
  sizes.each do |size|
    prefix = "中" * (size / 3)
    session.buffer = "#{prefix}😀终tail"
    matcher = Expect.const_get(:Matcher, false).new(Expect::PatternList.new([session], [/😀(终)(x)?/]), 0)
    verify = lambda do |result|
      ExpectBenchmark.check(result && result[2] == [prefix.bytesize, 7, ["终".b, nil]])
    end
    runner.measure("utf8/#{size}", bytes: session.buffer.bytesize, inputs: { prefix_bytes: prefix.bytesize },
                                   verify:) { matcher.__send__(:find_match) }
  end

  # 同一次等待不断追加新字节，分别对照字面与正则；跨块命中仍按声明优先级选择。
  (runner.smoke ? [4096] : [65_536, 1_048_576]).product(%i[literal regexp]).each do |size, kind|
    chunks = runner.smoke ? 4 : 32
    patterns = Array.new(32) { |index| "missing#{index}" }
    patterns[-1] = "END"
    patterns.map! { |value| Regexp.new(Regexp.escape(value)) } if kind == :regexp
    verify = lambda do |result|
      ExpectBenchmark.check(result && result[1].public_send(number_reader) == 32 &&
                            result[2] == [size + (chunks * 1024), 3, []])
    end
    runner.measure("stream/#{size}/#{kind}", bytes: size + (chunks * 1024) + 3,
                                             inputs: { initial_bytes: size, chunks:, patterns: 32, kind: },
                                             iterations: 5, verify:) do
      session.buffer = "x" * size
      matcher = Expect.const_get(:Matcher, false).new(Expect::PatternList.new([session], patterns), nil)
      ExpectBenchmark.check(matcher.__send__(:find_match).nil?)
      chunks.times do
        writer.write("x" * 1024)
        session.__send__(:read_available)
        ExpectBenchmark.check(matcher.__send__(:find_match).nil?)
      end
      writer.write("END")
      session.__send__(:read_available)
      matcher.__send__(:find_match)
    end
  end
ensure
  session.close
  reader.close
  writer.close
end

# 通过公开 expect 从真实管道逐块读取，覆盖未命中扫描与下一次追加的组合成本。
# 输入和 EOF 必须完整保留；不能只测静态扫描而遗漏 String 共享存储的写时复制。
(runner.smoke ? [65_536] : [1_048_576, 4_194_304, 16_777_216]).product(
  [[:literal, nil], [:literal, 65_536], [:regexp, nil], [:regexp, 65_536]]
).each do |size, (kind, window)|
  chunk = "x" * Expect.const_get(:READ_SIZE)
  expected = "x" * size
  verify = lambda do |result|
    ExpectBenchmark.check(result.eof? && result.before == expected)
  end
  inputs = { size:, kind:, search_window: window, chunk_bytes: chunk.bytesize }
  runner.measure("growing/#{size}/#{kind}/#{window || :full}", bytes: size, inputs:, iterations: 1, verify:) do
    input, output = IO.pipe
    source = Expect.open(input)
    sender = Thread.new do
      (size / chunk.bytesize).times { output.write(chunk) }
    ensure
      output.close
    end
    pattern = kind == :literal ? "never-present" : /never-present/
    result = source.expect(pattern, :eof, timeout: 30, search_window: window)
    ExpectBenchmark.check(sender.join(5), "producer did not complete")
    sender.value
    result
  ensure
    sender&.kill&.join if sender&.alive?
    source&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
  end
end

[1, 8, 32].each do |count|
  pipes = Array.new(count) { IO.pipe }
  sessions = pipes.map { |input, _| Expect.open(input) }
  begin
    sessions.each { |source| source.buffer = "x" * 4096 }
    list = Expect::PatternList.new
    # 每轮交替反转来源组，确保同一会话真实出现在多个非相邻组。
    8.times { |index| list.on(/missing/, from: index.even? ? sessions : sessions.reverse) }
    # 单会话的相邻相同组会合并；保持普通单会话路径作为对照。
    matcher = Expect.const_get(:Matcher, false).new(list, 0)
    runner.measure("groups/#{count}", bytes: 4096 * count, inputs: { sessions: count, groups: list.groups.size },
                                      verify: lambda { |result|
                                        ExpectBenchmark.check(result.nil?)
                                      }) { matcher.__send__(:find_match) }
    matcher.run
    verify = lambda do |result|
      ExpectBenchmark.check(result == :retry && sessions.all? { |source| source.buffer == "r" })
    end
    runner.measure("ready/#{count}", bytes: count, inputs: { sessions: count }, verify:) do
      sessions.each(&:clear_buffer)
      pipes.each { |pipe| pipe.last.write("r") }
      ready = IO.select(pipes.map(&:first), nil, nil, 0).first
      matcher.__send__(:read_ready, ready, sessions.map { |s| s })
    end
  ensure
    sessions.each(&:close)
    pipes.flatten.each(&:close)
  end
end
# 超时快照与继续回调的缓冲分配单独计量，不把未读取字节当作网络吞吐。
reader, writer = IO.pipe
session = Expect.open(reader)
begin
  payload = "x" * (runner.smoke ? 4096 : 1_048_576)
  session.buffer = payload
  # 两个接口均记录同一超时快照；在计时前选择入口，不修改基线库。
  record_timeout = if session.respond_to?(:record_timeout)
                     session.method(:record_timeout)
                   else
                     -> { session.record_error(:timeout) }
                   end
  runner.measure("snapshot/timeout", bytes: 0, inputs: { buffered_bytes: payload.bytesize }, iterations: 1000,
                                     verify: lambda { |result|
                                       ExpectBenchmark.check(result.timeout? && result.before == payload &&
                                                             result.before.frozen?)
                                     }) { record_timeout.call }
  session.clear_buffer
  runner.measure("snapshot/continue", bytes: 0, inputs: { buffered_bytes: payload.bytesize }, iterations: 1000,
                                      verify: lambda { |result|
                                        ExpectBenchmark.check(result.match == "DONE" && result.before.empty?)
                                      }) do
    session.buffer = "#{payload}?DONE"
    session.expect(timeout: 0) do |patterns|
      patterns.on("?") { Expect.continue }
      patterns.on("DONE")
    end
  end
ensure
  session.close
  reader.close
  writer.close
end
runner.finish
