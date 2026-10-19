# frozen_string_literal: true

require_relative "support"

# 独立计量扫描与状态查询，不把预置缓冲当作网络吞吐；各场景同时校验优先级与完整结果。
runner = ExpectBenchmark::Runner.new("dispatch")
handler = -> { false }
history = "".b
# 每个规则都从字节 0 命中，但只有首个声明可以胜出。
sequences = (1..32).to_h { |length| ["a" * length, handler] }
text = "a" * 64
runner.measure("escape/32-matches", bytes: 0, inputs: { rules: 32, matching: true }, iterations: 10_000,
                                    verify: lambda { |result|
                                      ExpectBenchmark.check(result == [[0, 1, handler], false, false])
                                    }) do
  Expect::Interaction.send(:scan_sequences, text, sequences, history, final: true)
end

reader, producer = IO.pipe
session = Expect.open(reader)
begin
  (runner.smoke ? [16] : [100, 400]).each do |count|
    calls = 0
    list = Expect::PatternList.new([session])
    count.times do
      list.on("x") do
        calls += 1
        Expect.continue
      end
    end
    list.finalize!
    verify_stalled = lambda do |result|
      ExpectBenchmark.check(result.timeout? && calls == count && session.buffer == "x")
    end
    runner.measure("matching/stalled/#{count}", bytes: 0, inputs: { patterns: count, consume: false },
                                                iterations: 1, verify: verify_stalled) do
      calls = 0
      session.buffer = "x"
      Expect.const_get(:Matcher, false).new(list, 0, consume: false).run
    end
  end

  # 多个借用会话共享同一 IO；关闭包装器只登记 EOF，不增加描述符或关闭共同来源。
  (runner.smoke ? [16] : [500, 2000, 4000]).each do |count|
    sources = Array.new(count) { Expect.open(reader).tap(&:close) }
    calls = 0
    list = Expect::PatternList.new(sources)
    list.eof do
      calls += 1
      Expect.continue
    end
    list.finalize!
    verify_eof = lambda do |result|
      ExpectBenchmark.check(result.eof? && result.session.equal?(sources.last) && calls == count)
    end
    runner.measure("matching/eof/#{count}", bytes: 0, inputs: { sessions: count, shared_io: true },
                                            iterations: 1, verify: verify_eof) do
      calls = 0
      Expect.const_get(:Matcher, false).new(list, nil).run
    end

    # EOF 回调继续时每个来源只派发一次，重复实参也不能重复派发。
    sources.each do |source|
      source.on_sequence(:eof) do
        calls += 1
        true
      end
    end
    runner.measure("relay/eof/#{count}", bytes: 0, inputs: { sessions: count, shared_io: true },
                                         iterations: 1, verify: lambda { |result|
                                           ExpectBenchmark.check(result.nil? && calls == count)
                                         }) do
      calls = 0
      Expect.interconnect(*sources, sources.first)
    end
  end

  responses = Expect::Responder.new
  16.times { |index| responses.on(/missing#{index}/n, reply: "unused") }
  session.buffer = "DONE#{"x" * (runner.smoke ? 1024 : 131_072)}"
  runner.measure("responder/first-completion", bytes: 0, inputs: { losing_rules: 16 }, iterations: 1000,
                                               verify: ->(result) { ExpectBenchmark.check(result.match == "DONE") }) do
    # 将上一结果归还为同一输入，记录快照成本计入基线与候选。
    result = responses.expect(session, "DONE", timeout: 1)
    session.buffer = "DONE#{result.after}"
    result
  end
ensure
  session.close
  reader.close
  producer.close
end

chunks = runner.smoke ? 8 : 1000
chunk = "x" * 1024
expected = chunk * chunks
runner.measure("redactor/after-suppressed-boundary", bytes: expected.bytesize,
                                                     inputs: { chunks:, chunk_bytes: chunk.bytesize }, iterations: 1,
                                                     verify: lambda { |result|
                                                       ExpectBenchmark.check(result == expected)
                                                     }) do
  filter = Expect::Redactor.new(["secret"])
  filter.suppress("disabled")
  filter.finish
  output = "".b
  chunks.times { output << filter.append(chunk) }
  output << filter.finish
end

# 不结束流就恢复可见级别；确认旧抑制字节排空后不会让后续可见分片一直携带资格图。
runner.measure("redactor/live-level-recovery", bytes: expected.bytesize,
                                               inputs: { chunks:, chunk_bytes: chunk.bytesize }, iterations: 1,
                                               verify: ->(result) { ExpectBenchmark.check(result == expected) }) do
  filter = Expect::Redactor.new(["secret"])
  filter.suppress("disabled")
  output = "".b
  chunks.times { output << filter.append(chunk) }
  output << filter.finish
end
runner.finish
