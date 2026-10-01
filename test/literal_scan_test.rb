# frozen_string_literal: true

require_relative "test_helper"

class LiteralScanTest < ExpectTest
  def test_new_bytes_can_complete_a_previously_missing_literal
    session, writer = pipe_session
    list = Expect::PatternList.new([session], ["password:", "word:"])
    matcher = Expect::Matcher.new(list, nil)
    session.buffer = "prefix pass"
    assert_nil matcher.__send__(:find_match)
    writer.write("word:")
    session.__send__(:read_available)
    result = matcher.__send__(:find_match)
    assert_equal 1, result[1].number
    assert_equal [7, 9, []], result[2]
  end

  def test_later_text_for_an_earlier_pattern_keeps_declaration_priority
    session, writer = pipe_session
    list = Expect::PatternList.new([session], %w[preferred ready])
    matcher = Expect::Matcher.new(list, nil)
    session.buffer = "ready"
    assert_equal 2, matcher.__send__(:find_match)[1].number
    writer.write(" preferred")
    session.__send__(:read_available)
    assert_equal 1, matcher.__send__(:find_match)[1].number
  end

  def test_destructive_buffer_changes_invalidate_old_misses
    session, writer = pipe_session
    list = Expect::PatternList.new([session], ["start", "token", /END/])
    matcher = Expect::Matcher.new(list, nil)
    session.buffer = "x" * 100
    assert_nil matcher.__send__(:find_match)
    session.buffer = "start"
    assert_equal 1, matcher.__send__(:find_match)[1].number
    session.clear_buffer
    assert_nil matcher.__send__(:find_match)
    writer.write("token")
    session.__send__(:read_available)
    assert_equal 2, matcher.__send__(:find_match)[1].number
    session.expect("token", timeout: 0)
    session.buffer_limit = 8
    writer.write("xxxxstart")
    session.__send__(:read_available)
    assert_equal [3, 5, []], matcher.__send__(:find_match)[2]
    session.clear_buffer
    session.__send__(:restore_relay_buffer, "token")
    assert_equal 2, matcher.__send__(:find_match)[1].number
  end

  def test_repeated_scans_equal_a_fresh_matcher_across_operation_sequences
    session, writer = pipe_session
    patterns = ["abc", "bc", "\0\xff".b, /END/n]
    list = Expect::PatternList.new([session], patterns)
    matcher = Expect::Matcher.new(list, nil)
    random = Random.new(40_033)
    chunks = ["a", "b", "c", "x", "END", "\0", "\xff".b]
    150.times do
      case random.rand(6)
      when 0
        session.buffer = chunks.sample(random:) * random.rand(1..4)
      when 1
        session.clear_buffer
      when 2
        session.buffer_limit = [nil, 2, 5, 12].sample(random:)
      when 3
        session.__send__(:restore_relay_buffer, chunks.sample(random:).b)
      when 4
        session.expect("x", timeout: 0).number
      else
        writer.write(chunks.sample(random:))
        session.__send__(:read_available)
      end
      expected = Expect::Matcher.new(list, nil).__send__(:find_match)
      actual = matcher.__send__(:find_match)
      assert_equal signature(expected), signature(actual), "buffer=#{session.buffer.inspect}"
    end
  end

  def test_registration_is_closed_when_the_matcher_is_constructed
    session, = pipe_session
    session.buffer = "prefix ready"
    list = Expect::PatternList.new([session], ["missing"])
    matcher = Expect::Matcher.new(list, nil)
    assert_nil matcher.__send__(:find_match)
    assert_raises(FrozenError) { list.on("prefix") }
    assert_nil matcher.__send__(:find_match)
  end

  private

  def signature(result)
    result ? [result[0], result[1].number, result[2]] : []
  end
end
