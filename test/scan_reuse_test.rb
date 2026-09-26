# frozen_string_literal: true

require_relative "test_helper"

class ScanReuseTest < ExpectTest
  def test_each_scan_snapshots_a_session_once_across_non_adjacent_groups
    first, = pipe_session
    second, = pipe_session
    first.buffer = "ready"
    list = Expect::PatternList.new
    list.on("missing", from: first).on("other", from: second).on("ready", from: first)
    matcher = Expect::Matcher.new(list, 0)
    snapshots = 0
    original = first.method(:buffer)
    first.stub(:buffer, lambda {
      snapshots += 1
      original.call
    }) do
      2.times do
        result = matcher.__send__(:find_match)
        assert_same first, result[0]
        assert_equal 3, result[1].number
        assert_equal [0, 5, []], result[2]
      end
    end
    assert_equal 2, snapshots
  end

  def test_callback_replacement_and_nested_match_are_visible_on_the_next_scan
    first, = pipe_session
    second, = pipe_session
    first.buffer = "start"
    events = []
    result = Expect.expect_result(timeout: 0) do
      on("start", from: first) do |session|
        events << session.match
        session.buffer = "nested finish"
        session.expect("nested ", timeout: 0)
        events << session.match
        session.continue
      end
      on("missing", from: second)
      on("finish", from: first) { |session| events << session.match }
    end
    assert_equal 3, result.number
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
    result = Expect.expect_result(timeout: 0) do
      on("missing", from: [first, second, other])
      on("other", from: other)
    end
    assert_same other, result.session
    assert_equal "first", first.buffer
    assert_empty second.buffer
  end

  def test_regexps_share_one_combined_text_and_literal_only_does_not_build_it
    session, = pipe_session
    session.listeners = [StringIO.new]
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
      assert Expect.__send__(:relay_buffer, session, { session => "payload".b })
      assert_equal count.zero? ? 0 : 1, concatenations
    end
  end

  def test_escape_callback_can_change_rules_before_rescanning
    session, = pipe_session
    output = StringIO.new
    session.listeners = [output]
    events = []
    session.on_sequence(/ONE/) do
      events << :one
      session.on_sequence(/TWO/) do
        events << :two
        false
      end
      true
    end
    buffers = { session => "aONEbTWOtail".b }
    refute Expect.__send__(:relay_buffer, session, buffers)
    assert_equal %i[one two], events
    assert_equal "ab", output.string
    assert_equal "tail", buffers.fetch(session)
  end
end
