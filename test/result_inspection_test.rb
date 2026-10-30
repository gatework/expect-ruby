# frozen_string_literal: true

require_relative "test_helper"

class ResultInspectionTest < ExpectTest
  def test_inspection_summarizes_a_match_without_exposing_raw_text
    session, = pipe_session
    session.redact("synthetic-secret")
    session.buffer = "prefix synthetic-secret suffix"
    result = session.expect(/(synthetic-secret)/, timeout: 0)

    summary = result.inspect
    refute_includes summary, "synthetic-secret"
    refute_includes summary, "prefix"
    refute_includes summary, "suffix"
    assert_includes summary, "match_number=1"
    assert_includes summary, "status=matched"
    refute_includes summary, "bytes="
    refute_includes summary, "captures="
    assert_equal "synthetic-secret", result.match
    assert_equal ["synthetic-secret"], result.captures
  end

  def test_inspection_never_inspects_an_exception_or_session
    failure = IOError.new("synthetic-error-secret")
    failure.define_singleton_method(:inspect) { raise "exception inspected" }
    source = Object.new
    source.define_singleton_method(:inspect) { raise "session inspected" }
    result = Expect::Result.new(status: :error, error: failure, session: source)

    assert_includes result.inspect, "status=error"
    refute_includes result.inspect, "synthetic-error-secret"
    assert_same failure, result.error
    assert_same source, result.session
  end

  def test_string_interpolation_uses_the_safe_summary
    result = Expect::Result.new(status: :error, before: "synthetic-secret", error: IOError.new("error-secret"))

    refute_includes "result=#{result}", "synthetic-secret"
    refute_includes result.to_s, "error-secret"
    assert_equal result.inspect, result.to_s
  end

  def test_inspection_distinguishes_eof_and_timeout_without_raw_output
    %i[eof timeout].each do |status|
      result = Expect::Result.new(status:, before: "\xFFsecret".b)
      assert_includes result.inspect, "status=#{status}"
      assert_includes result.inspect, "match_number=nil"
      refute_includes result.inspect, "secret"
    end
  end
end
