# frozen_string_literal: true

require_relative "test_helper"

class RelayHistoryTest < ExpectTest
  def test_matching_consumption_breaks_regexp_history_continuity
    session, producer, output = relaying_session
    producer.write("NOISE")
    assert_equal "NOISE", session.expect("NOISE", timeout: 0).match
    producer.write("OPtail")

    assert_nil Expect.interconnect(session, timeout: 0)
    assert_equal "STNOISEOPtail", output.string
    assert_empty session.buffer
  end

  def test_explicit_buffer_changes_cannot_join_old_history_to_new_input
    %i[replace clear trim].each do |operation|
      session, producer, output = relaying_session
      case operation
      when :replace
        session.buffer = "OPtail"
      when :clear
        session.clear_buffer
        producer.write("OPtail")
      when :trim
        producer.write("NOISEOPtail")
        assert session.expect("absent", consume: false, timeout: 0).timeout?
        session.buffer_limit = 6
      end

      assert_nil Expect.interconnect(session, timeout: 0), operation
      assert_equal operation == :trim ? "STNOISEOPtailOPtail" : "STOPtail", output.string
      assert_empty session.buffer
    end
  end

  def test_nonconsuming_match_and_empty_wait_keep_continuous_regexp_history
    session, producer, output = relaying_session
    assert session.expect("absent", timeout: 0).timeout?
    producer.write("OPtail")
    assert_equal "OP", session.expect("OP", consume: false, timeout: 0).match

    assert_same session, Expect.interconnect(session, timeout: 0)
    assert_equal "STOPtail", output.string
    assert_equal "tail", session.buffer
  end

  def test_consuming_zero_bytes_keeps_history_but_discarding_before_does_not
    session, producer, output = relaying_session
    assert_equal "", session.expect("", timeout: 0).match
    producer.write("OPtail")
    assert_same session, Expect.interconnect(session, timeout: 0)
    assert_equal "ST", output.string
    assert_equal "tail", session.buffer

    session, producer, output = relaying_session
    producer.write("NOISE")
    # 先用非消费匹配触发实际读取，再以尾部零宽匹配消费前缀。
    session.expect("NOISE", timeout: 0, consume: false)
    assert_equal "NOISE", session.expect(/\z/, timeout: 0).before
    producer.write("OPtail")
    assert_nil Expect.interconnect(session, timeout: 0)
    assert_equal "STNOISEOPtail", output.string
  end

  def test_invalid_buffer_changes_and_nontrimming_limits_preserve_history
    session, producer, output = relaying_session
    assert_raises(ArgumentError) { session.buffer = nil }
    assert_raises(ArgumentError) { session.buffer_limit = 0 }
    session.buffer_limit = 64
    producer.write("OPtail")

    assert_same session, Expect.interconnect(session, timeout: 0)
    assert_equal "ST", output.string
    assert_equal "tail", session.buffer
  end

  def test_long_literal_prefix_scan_matches_the_longest_possible_suffix
    key = "#{"a" * 2048}!".b
    sequences = { key.freeze => nil }
    prefix_tables = {}
    comparisons = 0
    buffer = "#{"a" * 128}?".b
    buffer.define_singleton_method(:end_with?) do |*_arguments|
      comparisons += 1
      false
    end

    assert_equal 0, Expect::Interaction.send(:hold_literal_prefix, buffer, sequences, prefix_tables)
    table = prefix_tables.fetch(key)
    assert_equal 129, table.length
    assert_equal 2048, Expect::Interaction.send(:hold_literal_prefix, "a" * 2048, sequences, prefix_tables)
    assert_same table, prefix_tables.fetch(key)
    assert_equal 2048, table.length
    assert_equal 0, comparisons
  end

  def test_literal_prefix_scan_matches_reference_for_binary_suffixes
    random = Random.new(47)
    200.times do
      key = Array.new(random.rand(1..100)) { random.rand(4) }.pack("C*")
      buffer = Array.new(random.rand(0..120)) { random.rand(4) }.pack("C*")
      expected = (1...[key.bytesize, buffer.bytesize + 1].min).to_a.reverse.find do |length|
        buffer.end_with?(key.byteslice(0, length))
      end || 0

      assert_equal expected, Expect::Interaction.send(:literal_prefix_suffix, buffer, key)
    end
  end

  def test_replacing_escape_rules_releases_unused_prefix_tables
    session, = pipe_session
    session.on_sequence("#{"a" * 256}!")
    Expect::Interaction.send(:hold_literal_prefix, "a" * 64, session.sequences,
                             session.literal_prefix_tables)

    refute_empty session.literal_prefix_tables
    session.__send__(:sequences=, {})
    assert_empty session.literal_prefix_tables
  end

  def test_nested_match_preserves_unconsumed_relay_tail_and_clears_consumed_history
    session, producer = pipe_session
    output = StringIO.new
    session.outputs = [output]
    session.on_sequence(/STOP/)
    session.on_sequence("!") do
      assert_equal "NOISE", session.expect("NOISE", timeout: 0).match
      true
    end
    session.on_sequence(:eof) { true }
    producer.write("ST!NOISEOPtail")
    producer.close

    assert_nil Expect.interconnect(session, timeout: 1)
    assert_equal "STOPtail", output.string
    assert_empty session.buffer
  end

  private

  def relaying_session
    session, producer = pipe_session
    output = StringIO.new
    session.outputs = [output]
    session.on_sequence(/STOP/)
    producer.write("ST")
    assert_nil Expect.interconnect(session, timeout: 0)
    assert_equal "ST", output.string
    [session, producer, output]
  end
end
