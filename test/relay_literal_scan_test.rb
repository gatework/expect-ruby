# frozen_string_literal: true

require_relative "test_helper"

class RelayLiteralScanTest < ExpectTest
  SIZE = Expect.const_get(:READ_SIZE)

  def test_large_unchanged_buffer_is_scanned_once_per_missing_literal
    session, producer = pipe_session
    producer.close
    session.read_available
    payload = "x" * (SIZE * 64)
    session.buffer = payload
    output = StringIO.new("".b)
    session.outputs = [output]
    session.on_sequence("MISSING_SENTINEL")
    cost = []
    buffer = session.scan_buffer
    original_index = buffer.method(:index)
    buffer.define_singleton_method(:index) do |key, offset = 0|
      cost << (bytesize - offset) if key == "MISSING_SENTINEL"
      original_index.call(key, offset)
    end
    assert_same session, Expect.interconnect(session, timeout: 2)
    assert_equal payload, output.string
    assert_operator cost.sum, :<=, payload.bytesize
  end

  def test_appended_input_matches_across_previously_scanned_tail_after_prefix_removed
    session, producer = pipe_session
    output = StringIO.new("".b)
    session.outputs = [output]
    session.on_sequence("STOP")
    prefix = "x" * (SIZE * 4)
    session.buffer = "#{prefix}ST"
    first = true
    original = output.method(:write)
    output.define_singleton_method(:write) do |data|
      count = original.call(data)
      if first
        first = false
        producer.write("OPtail")
      end
      count
    end
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal prefix, output.string
    assert_equal "tail", session.buffer
  end

  def test_nested_matcher_buffer_replacement_invalidates_cached_miss
    session, producer = pipe_session
    output = StringIO.new("".b)
    session.outputs = [output]
    session.on_sequence("STOP")
    prefix = "x" * SIZE
    session.buffer = "#{prefix}MARK"
    first = true
    original = output.method(:write)
    output.define_singleton_method(:write) do |data|
      count = original.call(data)
      if first
        first = false
        session.expect(timeout: 0) do |patterns|
          patterns.on("MARK") do
            session.buffer = "STOPtail"
            false
          end
        end
      end
      count
    end
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal prefix, output.string
    assert_equal "tail", session.buffer
    refute producer.closed?
  end

  def test_new_rule_and_target_changes_take_effect_at_next_chunk
    %i[rule target].each do |change|
      session, producer = pipe_session
      producer.close
      output = StringIO.new("".b)
      other = StringIO.new("".b)
      prefix = "x" * SIZE
      session.outputs = [output]
      session.buffer = "#{prefix}STOPtail"
      session.on_sequence("MISSING_SENTINEL")
      first = true
      original = output.method(:write)
      output.define_singleton_method(:write) do |data|
        count = original.call(data)
        if first
          first = false
          change == :rule ? session.on_sequence("STOP") : session.outputs = [other]
        end
        count
      end
      assert_same session, Expect.interconnect(session, timeout: 1)
      assert_equal prefix, output.string
      assert_equal(change == :rule ? "tail" : "", session.buffer)
      assert_equal(change == :target ? "STOPtail" : "", other.string)
    end
  end

  def test_replaced_callback_is_used_for_match_in_appended_input
    session, producer = pipe_session
    output = StringIO.new("".b)
    events = []
    session.outputs = [output]
    session.on_sequence("STOP") do
      events << :old
      false
    end
    session.buffer = "#{"x" * (SIZE * 2)}ST"
    first = true
    original = output.method(:write)
    output.define_singleton_method(:write) do |data|
      count = original.call(data)
      if first
        first = false
        session.on_sequence("STOP") do
          events << :new
          false
        end
        producer.write("OPtail")
      end
      count
    end
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal [:new], events
    assert_equal "x" * (SIZE * 2), output.string
    assert_equal "tail", session.buffer
  end

  def test_regexp_history_anchor_is_not_treated_as_a_literal_miss
    session, producer = pipe_session
    producer.close
    output = StringIO.new("".b)
    session.outputs = [output]
    session.buffer = "!#{"x" * (SIZE - 1)}STOPtail"
    session.on_sequence("!") do
      session.buffer_limit = 1
      true
    end
    session.on_sequence(/\ASTOP/n)
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal "#{"x" * (SIZE - 1)}S", output.string
    assert_equal "tail", session.buffer
  end
end
