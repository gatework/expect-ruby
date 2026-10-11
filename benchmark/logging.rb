# frozen_string_literal: true

require_relative "support"

# 同步日志目标的完整写入与短写使用同一记录，结果校验覆盖全部二进制字节和 flush 次数。
runner = ExpectBenchmark::Runner.new("logging")
size = runner.smoke ? 1024 : 262_144
data = ("\0\xffab".b * (size / 4)).freeze
verify = lambda do |result|
  ExpectBenchmark.check(result == [data, 1], "log bytes or flush count changed")
end
[nil, 64].each do |step|
  reader, producer = IO.pipe
  output = "".b
  flushes = 0
  target = Object.new
  target.define_singleton_method(:write) do |chunk|
    count = step ? [step, chunk.bytesize].min : chunk.bytesize
    output << chunk.byteslice(0, count)
    count
  end
  target.define_singleton_method(:flush) { flushes += 1 }
  begin
    # 会话和目标在采样外建立；每条记录重置结果，不把初始化成本计入持续补记性能。
    Expect.open(reader, transcript: target) do |session|
      runner.measure(step ? "short_writes" : "full_writes", bytes: data.bytesize,
                                                            inputs: { bytes: data.bytesize, accepted_per_write: step },
                                                            verify:, iterations: step ? 5 : 100) do
        output.clear
        flushes = 0
        session.write_transcript(data)
        [output, flushes]
      end
    end
  ensure
    reader.close
    producer.close
  end
end
runner.finish
