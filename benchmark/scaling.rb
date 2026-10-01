# frozen_string_literal: true

require_relative "support"

counts = [1, 16, 64]
runner = ExpectBenchmark::Runner.new("scaling") do |options|
  options.on("--sessions N", Integer, "Measure one explicit session count (check the process fd limit)") do |count|
    raise ArgumentError, "sessions must be positive" unless count.positive?

    counts = [count]
  end
end
counts = [1, 8] if runner.smoke
counts.each do |count|
  if (count * 2) + 32 > Process.getrlimit(:NOFILE).first
    raise ArgumentError, "#{count} sessions need a larger process fd limit; run ulimit -n before this benchmark"
  end

  pipes = []
  sessions = []
  begin
    count.times do
      pipes << IO.pipe
      sessions << Expect.open(pipes.last.first)
    end
    marker = "ready\n"
    ready_count = 0
    list = Expect::PatternList.new(sessions)
    list.on(marker) do
      ready_count += 1
      Expect.continue(reset_timeout: false) if ready_count < count
    end
    verify = lambda do |result|
      ExpectBenchmark.check(result.matched? && ready_count == count && sessions.all? { |source| source.buffer.empty? })
    end
    runner.measure("all_ready/#{count}", bytes: count * marker.bytesize, inputs: { sessions: count },
                                         iterations: 10, verify:) do
      ready_count = 0
      pipes.each { |pipe| pipe.last.write(marker) }
      Timeout.timeout(10) { Expect::Matcher.new(list, 5).run }
    end

    # 已知 EOF 逐个派发，仍须保留来源顺序、尾部快照，并在全部结束后返回 EOF。
    sessions.each(&:close)
    ended = []
    list = Expect::PatternList.new(sessions)
    list.eof do |source|
      ended << source
      Expect.continue(reset_timeout: false)
    end
    verify = lambda do |result|
      ExpectBenchmark.check(result.eof? && ended == sessions && sessions.all? do |source|
        source.before == "tail" && source.buffer.empty?
      end)
    end
    runner.measure("all_eof/#{count}", bytes: count * 4, inputs: { sessions: count }, iterations: 10, verify:) do
      ended.clear
      sessions.each { |source| source.buffer = "tail" }
      Timeout.timeout(10) { Expect::Matcher.new(list, 5).run }
    end
  ensure
    sessions.each(&:close)
    pipes.flatten.each { |io| io.close unless io.closed? }
  end
end

# 真实管道填满后完全不消费；另一个来源的标记仍须被读到，重复进入不能增长描述符。
pipes = Array.new(3) { IO.pipe }
slow = Expect.open(pipes[0].first)
fast = Expect.open(pipes[1].first)
sink = pipes[2].last
begin
  loop { break if sink.write_nonblock("x" * 4096, exception: false) == :wait_writable }
  slow.outputs = [sink]
  fast.on_sequence("PROBE")
  verify = lambda do |result|
    ExpectBenchmark.check(result.equal?(fast) && slow.pending_output? && fast.buffer.empty?)
  end
  runner.measure("blocked_target_probe", bytes: 5, inputs: { sources: 2, blocked_targets: 1 },
                                         iterations: 100, verify:) do
    slow.buffer = "blocked"
    pipes[1].last.write("PROBE")
    Timeout.timeout(10) { Expect.interconnect(slow, fast, timeout: 5) }
  end
ensure
  [slow, fast].each(&:close)
  pipes.flatten.each { |io| io.close unless io.closed? }
end
runner.finish
