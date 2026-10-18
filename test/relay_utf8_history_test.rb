# frozen_string_literal: true

require_relative "test_helper"

class RelayUtf8HistoryTest < ExpectTest
  def test_small_history_preserves_every_utf8_partition_across_timeouts
    ["é", "中", "😀"].each do |character|
      partitions(character.b).each do |chunks|
        (1..5).each do |limit|
          with_relay(character, buffer_limit: limit) do |session, producer, output, events|
            chunks.each_with_index do |chunk, index|
              producer.write(chunk + (index == chunks.size - 1 ? "tail" : ""))
              stopped = Expect.interconnect(session, timeout: 0)
              if index == chunks.size - 1
                assert_same session, stopped
              else
                assert_nil stopped
                assert_nil Expect.interconnect(session, timeout: 0)
                assert_equal chunks.take(index + 1).join, output.string
                assert_operator session.relay_history.bytesize, :<=, [limit, 3].max
              end
            end
            assert_equal [:first], events
            assert_equal chunks.take(chunks.size - 1).join, output.string
            assert_equal "tail", session.buffer
          end
        end
      end
    end
  end

  def test_reducing_history_limit_preserves_an_incomplete_character
    [1, 2].each do |limit|
      with_relay("😀", buffer_limit: 16) do |session, producer, output, events|
        producer.write("noise#{"😀".b.byteslice(0, 3)}")
        assert_nil Expect.interconnect(session, timeout: 0)
        session.buffer_limit = limit
        # 空轮询也会重新裁剪已转发历史，不能丢掉未完成的字符。
        assert_nil Expect.interconnect(session, timeout: 0)
        assert_operator session.relay_history.bytesize, :<=, 3
        producer.write("#{"😀".b.byteslice(3, 1)}tail")
        assert_same session, Expect.interconnect(session, timeout: 0)
        assert_equal [:first], events
        assert_equal "noise#{"😀".b.byteslice(0, 3)}", output.string
        assert_equal "tail", session.buffer
      end
    end
  end

  def test_complete_characters_can_be_discarded_at_the_history_boundary
    (1..5).each do |limit|
      with_relay("😀", buffer_limit: limit) do |session, producer, output, events|
        producer.write("中" * 8)
        assert_nil Expect.interconnect(session, timeout: 0)
        history = session.relay_history
        assert_operator history.bytesize, :<=, [limit, 3].max
        assert history.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        producer.write("😀")
        assert_same session, Expect.interconnect(session, timeout: 0)
        assert_equal "中" * 8, output.string.force_encoding(Encoding::UTF_8)
        assert_equal [:first], events
      end
    end
  end

  def test_small_history_still_rejects_truncated_and_invalid_utf8
    [1, 2].each do |limit|
      ["\xf0\x9f\x98".b, "\xe4\xb8".b].each do |prefix|
        with_relay("😀", buffer_limit: limit) do |session, producer, output, events|
          producer.write(prefix)
          assert_nil Expect.interconnect(session, timeout: 0)
          producer.close
          assert_raises(EncodingError) { Expect.interconnect(session, timeout: 1) }
          assert_equal prefix, output.string
          assert_empty events
        end
      end
      with_relay("😀", buffer_limit: limit) do |session, producer, _output, events|
        producer.write("\xf0\x9f\x98".b)
        assert_nil Expect.interconnect(session, timeout: 0)
        producer.write("x")
        assert_raises(EncodingError) { Expect.interconnect(session, timeout: 0) }
        assert_equal "x", session.buffer
        assert_empty events
      end
    end
  end

  private

  # 枚举字符内部所有切分位置组合，覆盖逐字节和多字节分片。
  def partitions(bytes)
    (0...(1 << (bytes.bytesize - 1))).map do |mask|
      boundaries = (1...bytes.bytesize).select { |index| mask[index - 1] == 1 }
      [0, *boundaries, bytes.bytesize].each_cons(2).map { |first, last| bytes.byteslice(first...last) }
    end
  end

  def with_relay(character, buffer_limit:)
    output = StringIO.new("".b)
    events = []
    session, producer = pipe_session(buffer_limit:, outputs: [output])
    session.on_sequence(/NEVER/n)
    session.on_sequence("STOP")
    session.on_sequence(Regexp.new(character)) do
      events << :first
      false
    end
    session.on_sequence(Regexp.new("(?:#{character})")) do
      events << :second
      false
    end
    yield session, producer, output, events
  ensure
    session&.close
    session&.to_io&.close unless session&.to_io&.closed?
    producer&.close unless producer&.closed?
  end
end
