# frozen_string_literal: true

require_relative "test_helper"

class ScanReuseTest < ExpectTest
  def test_registered_regexp_is_reused_across_reads_and_history_boundaries
    session, producer = pipe_session
    output = StringIO.new
    session.outputs = [output]
    session.on_sequence(/STOP/n)

    producer.write("ST")
    assert_nil Expect.interconnect(session, timeout: 0)
    Expect.const_get(:Pattern).stub(:new, ->(*) { flunk "regexp recompiled while reading" }) do
      producer.write("OPtail")
      assert_same session, Expect.interconnect(session, timeout: 1)
    end
    assert_equal "ST", output.string
    assert_equal "tail", session.buffer
  end

  def test_regexp_compilation_is_deferred_until_rules_are_used
    session, = pipe_session
    pattern = Expect.const_get(:Pattern)
    pattern.stub(:new, ->(*) { flunk "compilation during registration" }) do
      16.times { |index| session.on_sequence(/missing#{index}/n) }
    end
    original = pattern.method(:new)
    compiled = []
    pattern.stub(:new, lambda { |**fields|
      compiled << fields.fetch(:value)
      original.call(**fields)
    }) do
      session.buffer = "ready"
      2.times { assert_nil Expect.interconnect(session, timeout: 0) }
    end
    assert_equal session.sequences.keys, compiled
  end

  def test_escape_registration_publishes_readonly_snapshots
    session, = pipe_session
    session.on_sequence(/STOP/n)
    rules = session.sequences
    assert_raises(FrozenError) { rules.clear }
    session.on_sequence("DONE")
    assert_equal [/STOP/n], rules.keys
    assert_equal [/STOP/n, "DONE"], session.sequences.keys
    assert session.text_sequences.frozen?
    assert session.sequence_patterns.frozen?
  end

  def test_reordered_escape_snapshot_changes_the_tie_winner
    session, = pipe_session
    calls = []
    session.on_sequence("STOP") do
      calls << :literal
      false
    end
    session.on_sequence(/STOP/n) do
      calls << :regexp
      false
    end
    session.sequences = session.sequences.to_a.reverse.to_h
    session.buffer = "STOPtail"

    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal [:regexp], calls
    assert_equal "tail", session.buffer
  end

  def test_each_stalled_declaration_runs_once_even_with_equal_pattern_values
    session, = pipe_session
    session.buffer = "x"
    seen = []

    result = session.expect(timeout: 0, consume: false) do |patterns|
      128.times do
        patterns.on("x") do |source|
          seen << source.match_number
          Expect.continue
        end
      end
    end

    assert result.timeout?
    assert_equal (1..128).to_a, seen
    assert_equal "x", session.buffer
  end

  def test_escape_scan_preserves_registration_ties_and_historical_offsets
    first = -> { false }
    second = -> { true }
    scan = ->(buffer, sequences, history) { Expect::Interaction.send(:scan_sequences, buffer, sequences, history, final: true) }

    result = scan.call("STOP".b, { "STOP".b => first, /STOP/n => second }, "".b)
    assert_equal [[0, 4, first], true, false], result
    result = scan.call("OPtail".b, { "OP".b => first, /STOP/n => second }, "ST".b)
    assert_equal [[-2, 4, second], true, false], result
  end

  def test_escape_scan_still_validates_later_regexps_after_a_zero_position_winner
    assert_raises(ArgumentError) do
      Expect::Interaction.send(:scan_sequences, "STOP".b, { "STOP".b => nil, /(?=STOP)/ => nil }, "".b,
                               final: true)
    end
    found, scanned, utf8 = Expect::Interaction.send(:scan_sequences, "STOP".b,
                                                    { "STOP".b => nil, /确认/u => nil }, "".b, final: true)
    assert_equal [0, 4, nil], found
    assert scanned
    assert utf8
  end

  def test_terminal_match_without_callback_does_not_copy_a_progress_snapshot
    session, = pipe_session
    session.buffer = "output READY tail"
    session.stub(:buffer, -> { flunk "unnecessary progress snapshot" }) do
      result = session.expect("READY", timeout: 0)
      assert_equal "output ", result.before
      assert_equal " tail", result.after
    end
  end

  def test_continuing_match_only_takes_one_progress_snapshot
    session, = pipe_session
    session.buffer = "question?DONE"
    copies = 0
    original = session.method(:buffer)
    session.stub(:buffer, lambda {
      copies += 1
      original.call
    }) do
      result = session.expect(timeout: 0) do |patterns|
        patterns.on("question?") { Expect.continue }
        patterns.on("DONE")
      end
      assert result.matched?
    end
    assert_equal 1, copies
  end

  def test_error_snapshot_does_not_use_an_extra_public_buffer_copy
    session, = pipe_session
    session.buffer = "retained output"
    result = nil
    session.stub(:buffer, -> { flunk "unnecessary intermediate error snapshot" }) do
      result = session.record_timeout
    end
    session.buffer = "next output"
    assert_equal "retained output", result.before
    assert result.before.frozen?
  end

  def test_each_scan_borrows_a_session_buffer_once_across_non_adjacent_groups
    first, = pipe_session
    second, = pipe_session
    first.buffer = "ready"
    list = Expect::PatternList.new
    list.on("missing", from: first).on("other", from: second).on("ready", from: first)
    matcher = Expect.const_get(:Matcher, false).new(list, 0)
    borrows = 0
    original = first.method(:scan_buffer)
    first.stub(:scan_buffer, lambda {
      borrows += 1
      original.call
    }) do
      2.times do
        result = matcher.__send__(:find_match)
        assert_same first, result[0]
        assert_equal 3, result[1].match_number
        assert_equal [0, 5, []], result[2]
      end
    end
    assert_equal 2, borrows
  end

  def test_callback_replacement_and_nested_match_are_visible_on_the_next_scan
    first, = pipe_session
    second, = pipe_session
    first.buffer = "start"
    events = []
    result = Expect.expect(timeout: 0) do
      on("start", from: first) do |session|
        events << session.match
        session.buffer = "nested finish"
        session.expect("nested ", timeout: 0)
        events << session.match
        Expect.continue
      end
      on("missing", from: second)
      on("finish", from: first) { |session| events << session.match }
    end
    assert_equal 3, result.match_number
    assert_equal ["start", "nested ", "finish"], events
    assert_empty first.buffer
  end

  def test_shared_io_keeps_first_session_and_identity_despite_equal_hashes
    first, writer = pipe_session
    second = Expect.open(first.to_io)
    @sessions << second
    other, other_writer = pipe_session
    # IO 的业务相等性不能替代 IO.select 返回对象的身份。
    [first.to_io, other.to_io].each do |io|
      io.define_singleton_method(:hash) { 0 }
      io.define_singleton_method(:eql?) { |_other| true }
    end
    writer.write("first")
    other_writer.write("other")
    result = Expect.expect(timeout: 0) do
      on("missing", from: [first, second, other])
      on("other", from: other)
    end
    assert_same other, result.session
    assert_equal "first", first.buffer
    assert_empty second.buffer
  end

  def test_regexps_share_one_combined_text_and_literal_only_does_not_build_it
    session, = pipe_session
    session.outputs = [StringIO.new]
    [0, 4].each do |count|
      session.__send__(:sequences=, {})
      count.times { |index| session.on_sequence(/missing#{index}/) }
      session.on_sequence("STOP")
      history = session.__send__(:relay_history)
      concatenations = 0
      original = history.method(:+)
      history.define_singleton_method(:+) do |other|
        concatenations += 1
        original.call(other)
      end
      assert_equal :queued, Expect::Interaction.queue_input(session, "payload".b)
      assert_equal count.zero? ? 0 : 1, concatenations
    end
  end

  def test_escape_callback_can_change_rules_before_rescanning
    session, = pipe_session
    output = StringIO.new
    session.outputs = [output]
    events = []
    session.on_sequence(/ONE/) do
      events << :one
      session.on_sequence(/TWO/) do
        events << :two
        false
      end
      true
    end
    session.buffer = "aONEbTWOtail"
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal %i[one two], events
    assert_equal "ab", output.string
    assert_equal "tail", session.buffer
  end
end
