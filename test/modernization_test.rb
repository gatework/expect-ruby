# frozen_string_literal: true

require_relative "test_helper"

class ModernizationTest < ExpectTest
  def test_result_copies_and_freezes_values_without_freezing_the_session_or_error
    session, = pipe_session
    failure = IOError.new("read failed")
    text = +"bytes"
    captures = [+"capture", nil]
    result = Expect::Result.new(before: text, match: text, after: text, captures:, session:, error: failure)
    text.clear
    captures.first.clear
    captures.clear

    assert_instance_of Expect::Result, result
    assert_kind_of Data, result
    assert_equal "bytes", result.before
    assert_equal ["capture", nil], result.captures
    [result, result.before, result.match, result.after, result.captures, result.captures.first].each do |value|
      assert_predicate value, :frozen?
    end
    assert_raises(FrozenError) { result.captures << "other" }
    assert_raises(FrozenError) { result.match.clear }
    refute_respond_to result, :before=
    refute_respond_to result, :to_a
    assert_same failure, result.error
    refute_predicate failure, :frozen?
    refute_predicate session, :frozen?
    changed = result.with(before: +"changed")
    assert_predicate changed.before, :frozen?
    assert_equal "bytes", result.before
  end

  def test_public_results_and_fluent_methods_keep_the_same_session
    session, writer = pipe_session
    assert_same session, session.on_sequence("stop")
    assert_same session, session.redact("secret")
    writer.write("ready")
    result = session.expect(timeout: 1) do |patterns|
      patterns.on("ready") { |connection| assert_same session, connection }
    end
    assert_same session, result.session
    %i[session connection resources].each do |name|
      refute_respond_to session, name
    end
  end

  def test_failed_transcript_flush_preserves_both_borrowed_targets
    session, = pipe_session
    original = RuntimeError.new("old transcript failed")
    old = StringIO.new
    fresh = StringIO.new
    @ios.push(old, fresh)
    session.transcript = old
    session.redact("secret")
    session.write_transcript("sec")
    old.stub(:write, ->(*) { raise original }) do
      error = assert_raises(RuntimeError) { session.transcript = fresh }
      assert_same original, error
      assert_same old, session.transcript
    end
    refute old.closed?
    refute fresh.closed?
  end

  def test_open_closes_owned_handles_on_throw_and_nonlocal_return
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    assert_equal :done, catch(:finished) {
      Expect.open(reader, own: true) { throw :finished, :done }
    }
    assert_predicate reader, :closed?

    reader, writer = IO.pipe
    @ios.push(reader, writer)
    assert_equal :returned, return_from_open(reader)
    assert_predicate reader, :closed?
  end

  def test_cleanup_failure_on_throw_is_visible
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    failure = IOError.new("close failed")
    reader.stub(:close, -> { raise failure }) do
      error = assert_raises(IOError) do
        catch(:finished) { Expect.open(reader, own: true) { throw :finished } }
      end
      assert_same failure, error
    end
  end

  private

  def return_from_open(reader)
    Expect.open(reader, own: true) { return :returned }
  end
end
