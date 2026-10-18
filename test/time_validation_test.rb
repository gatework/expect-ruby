# frozen_string_literal: true

require_relative "test_helper"

class TimeValidationTest < ExpectTest
  def test_duration_rejects_non_numeric_and_non_real_values_consistently
    ["0x10", "0.5", true, :a, Object.new, Complex(1, 0), -1, Float::NAN, Float::INFINITY].each do |value|
      assert_raises(ArgumentError, value.inspect) { Expect.duration(value) }
    end
    assert_nil Expect.duration(nil)
    assert_equal 0.5, Expect.duration(Rational(1, 2))
    assert_equal 0.0, Expect.duration(0)
  end

  def test_absolute_deadline_is_numeric_but_may_already_be_expired
    session, = pipe_session
    ["0", true, :a, Complex(1, 0), Float::NAN, Float::INFINITY].each do |value|
      assert_raises(ArgumentError, value.inspect) { session.expect("x", deadline: value) }
    end
    assert session.expect("x", deadline: -1).timeout?
  end
end
