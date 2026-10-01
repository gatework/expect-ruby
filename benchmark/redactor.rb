# frozen_string_literal: true

require_relative "support"

# 同一驱动可加载基线或候选库；每轮创建独立过滤器，不能跨样本继承流状态。
module RedactorBenchmark
  def self.measure(runner, name, input, patterns, expected, chunk_size: nil, partial: false, iterations: 5)
    chunks = if chunk_size
               (0...input.bytesize).step(chunk_size).map { |offset| input.byteslice(offset, chunk_size) }
             else
               [input]
             end
    runner.measure(name, bytes: input.bytesize,
                         inputs: { bytes: input.bytesize, secret_lengths: patterns.map(&:bytesize),
                                   chunk_size:, partial:, repeated_finish: true },
                         verify: ->(output) { ExpectBenchmark.check(output == expected, "incorrect #{name} output") },
                         iterations:) do
      filter = Expect::Redactor.new(patterns)
      output = +"".b
      chunks.each { |chunk| output << filter.append(chunk) }
      output << filter.finish(partial:) << filter.finish(partial:)
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
                            ["secret"], "prefix [FILTERED]!\n" * count, chunk_size:)
end
[true, false].each do |partial|
  RedactorBenchmark.measure(runner, "partial_#{partial}", "prefix pass", ["password"],
                            partial ? "prefix [FILTERED]" : "prefix pass", chunk_size: 1, partial:)
end

tail_size = runner.smoke ? 32 : 4096
tail = "a" * tail_size
half_tail = tail.byteslice(0, tail_size / 2)
RedactorBenchmark.measure(runner, "long_tail_without_prefix", "#{tail}b", ["#{tail}c"], "#{tail}b",
                          partial: true, iterations: 100)
RedactorBenchmark.measure(runner, "long_tail_dense_candidates", "#{half_tail}c#{half_tail}",
                          ["#{tail}bc"], "#{half_tail}c[FILTERED]", partial: true, iterations: 100)

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
