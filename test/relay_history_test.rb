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
