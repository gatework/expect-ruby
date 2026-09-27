# frozen_string_literal: true

require_relative "support"

# 同一驱动可加载基线或候选库；每轮创建独立过滤器，不能跨样本继承流状态。
module RedactorBenchmark
  def self.measure(runner, name, input, patterns, expected, chunk_size: nil, partial: false)
    chunks = if chunk_size
               (0...input.bytesize).step(chunk_size).map { |offset| input.byteslice(offset, chunk_size) }
             else
               [input]
             end
    runner.measure(name, bytes: input.bytesize,
                         inputs: { bytes: input.bytesize, secret_lengths: patterns.map(&:bytesize),
                                   chunk_size: chunk_size, partial: partial, repeated_finish: true },
                         verify: ->(output) { ExpectBenchmark.check(output == expected, "incorrect #{name} output") },
                         iterations: 5) do
      filter = Expect::Redactor.new(patterns)
      output = +"".b
      chunks.each { |chunk| output << filter.append(chunk) }
      output << filter.finish(partial: partial) << filter.finish(partial: partial)
    end
  end
end

runner = ExpectBenchmark::Runner.new("redactor")
size = runner.smoke ? 512 : 65_536
plain = "x" * size
RedactorBenchmark.measure(runner, "empty_rules", plain, [], plain)
RedactorBenchmark.measure(runner, "no_match", plain, ["secret"], plain)
RedactorBenchmark.measure(runner, "no_match_many", plain, %w[secret password token credential], plain)
RedactorBenchmark.measure(runner, "sparse", "#{plain}secret!", ["secret"], "#{plain}[FILTERED]!")
RedactorBenchmark.measure(runner, "contiguous_short", "token" * (size / 5), ["token"], "[FILTERED]")

(runner.smoke ? [1, 32, 128] : [1, 32, 1024, 4096]).each do |length|
  RedactorBenchmark.measure(runner, "overlap_#{length}", "a" * size, ["a" * length], "[FILTERED]")
end
count = runner.smoke ? 8 : 256
RedactorBenchmark.measure(runner, "contained_patterns", "abcde!" * count,
                          %w[abc bc ab bcd], "[FILTERED]e!" * count)
RedactorBenchmark.measure(runner, "binary_overlap", "\0\xffABC\x80!".b * count,
                          ["\xffABC".b, "ABC\x80".b], "\0[FILTERED]!".b * count, chunk_size: 3)
RedactorBenchmark.measure(runner, "marker_in_input", "[FILTERED] secret!" * count,
                          %w[secret FILTERED], "[[FILTERED]] [FILTERED]!" * count)

[1, 7, 4096].each do |chunk_size|
  RedactorBenchmark.measure(runner, "stream_#{chunk_size}", "prefix secret!\n" * count,
                            ["secret"], "prefix [FILTERED]!\n" * count, chunk_size: chunk_size)
end
[true, false].each do |partial|
  RedactorBenchmark.measure(runner, "partial_#{partial}", "prefix pass", ["password"],
                            partial ? "prefix [FILTERED]" : "prefix pass", chunk_size: 1, partial: partial)
end

runner.measure("update_pending", bytes: 10, inputs: { update: "keep old mask and match new secret" },
                                 verify: lambda { |output|
                                   ExpectBenchmark.check(output == "[FILTERED]!")
                                 }, iterations: 100) do
  filter = Expect::Redactor.new(%w[abc long-pattern])
  output = filter.append("abcsec")
  filter.patterns = ["secret"]
  output << filter.append("ret!") << filter.finish << filter.finish
end
runner.finish
