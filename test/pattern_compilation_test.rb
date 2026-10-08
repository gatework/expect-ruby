# frozen_string_literal: true

require_relative "test_helper"

class PatternCompilationTest < ExpectTest
  def test_explicit_freeze_in_the_public_dsl_also_compiles_the_rules
    source, = pipe_session
    source.buffer = "ready"

    result = source.expect(timeout: 0) do
      on("ready")
      freeze
    end

    assert result.matched?
    assert_equal "ready", result.match
    assert_empty source.buffer
  end

  def test_eof_only_wait_does_not_scan_text_buffers
    sources = Array.new(16) { pipe_session.first }
    scans = 0
    sources.each_with_index do |source, index|
      source.buffer = "tail-#{index}"
      source.close
      original = source.method(:scan_buffer)
      source.define_singleton_method(:scan_buffer) do
        scans += 1
        original.call
      end
    end
    seen = []

    result = Expect.expect(from: sources, timeout: nil) do
      eof do |source|
        seen << [source, source.before]
        Expect.continue
      end
    end

    assert result.eof?
    assert_same sources.last, result.session
    assert_equal sources.each_with_index.map { |source, index| [source, "tail-#{index}"] }, seen
    assert_equal 0, scans
  end

  def test_shared_eof_declarations_keep_identity_order_and_can_be_reused
    first, = pipe_session
    second, = pipe_session
    third, = pipe_session
    equalize_sessions(first, second)
    [first, second, third].each(&:close)
    seen = []
    list = Expect::PatternList.new([second, first, second, third])
    list.eof(from: [first, second, first]) do |source|
      seen << [:shared, source.object_id, source.before]
      Expect.continue
    end
    list.eof(from: third) do
      seen << [:third, third.object_id, third.before]
      Expect.continue
    end
    list.eof(from: [second, first]) do |source|
      seen << [:last, source.object_id, source.before]
      Expect.continue
    end

    2.times do
      seen.clear
      [first, second, third].each { |source| source.buffer = "tail" }
      result = Expect::Matcher.new(list, nil).run

      assert result.eof?
      assert_same third, result.session
      assert_equal [[:shared, second.object_id, "tail"], [:last, second.object_id, "tail"],
                    [:shared, first.object_id, "tail"], [:last, first.object_id, "tail"],
                    [:third, third.object_id, "tail"]], seen
      assert_predicate list, :frozen?
      assert_equal [second.object_id, first.object_id, third.object_id], list.sessions.map(&:object_id)
    end
  end

  def test_default_sources_without_rules_are_still_collected_and_notified_on_timeout
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.write("first")
    second_writer.write("second")
    notified = nil

    result = Expect.expect(from: [second, first, second], timeout: 0) do
      timeout { |sources| notified = sources }
    end

    assert result.timeout?
    assert_same second, result.session
    assert_equal [second, first], notified
    assert_equal "first", first.buffer
    assert_equal "second", second.buffer
  end

  def test_eof_callback_can_make_an_earlier_source_ready_before_later_eof_dispatch
    first, = pipe_session
    second, = pipe_session
    third, = pipe_session
    [second, third].each(&:close)
    seen = []
    list = Expect::PatternList.new([first, second, third])
    list.on("ready", from: first) do |source|
      seen << source.match
      Expect.continue
    end
    list.eof(from: second) do
      seen << :second
      first.buffer = "ready"
      first.close
      Expect.continue
    end
    list.eof(from: first) do
      seen << :first
      Expect.continue
    end
    list.eof(from: third) do
      seen << :third
      Expect.continue
    end

    result = Expect::Matcher.new(list, nil).run

    assert result.eof?
    assert_same third, result.session
    assert_equal [:second, "ready", :first, :third], seen
  end
end
