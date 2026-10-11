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
      Expect::Matcher.new(list, 0, consume: false).run
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
runner.finish
