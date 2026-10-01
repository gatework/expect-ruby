# frozen_string_literal: true

require_relative "test_helper"

class SessionIdentityTest < ExpectTest
  def test_nonconsuming_match_stalls_only_the_source_that_already_ran
    first, = pipe_session
    second, = pipe_session
    equalize_sessions(first, second)
    [first, second].each { |session| session.buffer = "ready" }
    seen = []

    result = Expect.expect(from: [first, second], timeout: 0, consume: false) do
      on("ready") do |session|
        seen << session
        Expect.continue if seen.size == 1
      end
    end

    assert result.matched?
    assert_same second, result.session
    assert_equal 2, seen.size
    assert_same first, seen[0]
    assert_same second, seen[1]
    assert_equal "ready", first.buffer
    assert_equal "ready", second.buffer
  end

  def test_nested_matching_returns_each_equal_sources_tail_to_its_relay
    first, = pipe_session
    second, = pipe_session
    equalize_sessions(first, second)
    output = StringIO.new
    first.buffer = "!first"
    second.buffer = "second"
    second.outputs = [output]
    matched = nil
    first.on_sequence("!") do
      matched = Expect.expect("first", from: [first, second], timeout: 0)
      true
    end

    assert_nil Expect.interconnect(first, second, timeout: 0)
    assert matched.matched?
    assert_same first, matched.session
    assert_equal "second", output.string
    assert_empty first.buffer
    assert_empty second.buffer
  end
end
