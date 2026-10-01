# frozen_string_literal: true

require_relative "support"

runner = ExpectBenchmark::Runner.new("send_slow")
size = runner.smoke ? 8 : 128
payload = "x" * size
[false, true].product([0, 0.001]).each do |echo, delay|
  verify = lambda do |result|
    count, received, reply = result
    ExpectBenchmark.check(count == size && received == payload && reply == (echo ? payload : nil))
  end
  runner.measure("send/#{echo ? "echo" : "silent"}/#{delay}", bytes: size,
                                                              inputs: { size:, echo:, delay: },
                                                              iterations: 1, verify:) do
    client, peer = Socket.pair(:UNIX, :STREAM, 0)
    session = Expect.open(client)
    consumer = Thread.new do
      received = "".b
      while received.bytesize < size
        data = peer.readpartial(size)
        received << data
        peer.write(data) if echo
      end
      received
    end
    begin
      Timeout.timeout(10) do
        count = session.send_slow(payload, delay:)
        reply = session.expect(payload, timeout: 2).match if echo
        [count, consumer.value, reply]
      end
    ensure
      consumer.kill.join
      session.close
      client.close
      peer.close
    end
  end
end
runner.finish
