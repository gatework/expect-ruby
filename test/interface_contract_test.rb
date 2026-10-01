# frozen_string_literal: true

require_relative "test_helper"

class InterfaceContractTest < ExpectTest
  def test_expect_returns_results_and_keeps_convenient_snapshot_readers
    session, writer = pipe_session
    assert_nil session.last_result
    assert_equal [nil, nil, nil, nil, [], nil], snapshot(session)
    session.buffer = "prefix ready7 tail"
    result = Expect.expect(/ready(\d)/, from: session, timeout: 0)
    assert_instance_of Expect::Result, result
    assert_same result, session.last_result
    assert_equal [result.before, result.after, result.match, result.number, result.captures, result.error],
                 snapshot(session)
    assert result.matched?
    assert session.expect("missing", timeout: 0).timeout?
    assert_equal :timeout, session.error
    assert_nil session.match_number
    assert_empty session.captures
    writer.close
    assert session.expect(:eof, timeout: 1).eof?
    assert_equal :eof, session.error
    refute_respond_to session, :expect_result
    refute_respond_to Expect, :expect_result
  end

  def test_boolean_configuration_uses_only_predicates_and_setters
    session, = pipe_session
    booleans = %i[raw_pty preserve_buffer log_stdout log_listeners raw_terminal reset_timeout_on_read graceful_close]
    booleans.each do |name|
      config = Expect::Configuration.new(**{ name => 0 })
      [config, session].each do |target|
        refute_respond_to target, name
        target.public_send(:"#{name}=", 0)
        assert target.public_send(:"#{name}?")
        target.public_send(:"#{name}=", nil)
        refute target.public_send(:"#{name}?")
      end
      assert_equal false, config.to_h.fetch(name)
      assert_raises(FrozenError) { config.freeze.public_send(:"#{name}=", true) }
    end
  end

  def test_callback_cannot_change_finalized_rules
    session, = pipe_session
    session.buffer = "ready"
    list = nil
    callback = lambda do |_connection|
      refute_predicate session, :frozen?
      assert_raises(FrozenError) { list.on("later") }
      assert_raises(FrozenError) { list.eof }
      assert_raises(FrozenError) { list.timeout }
    end
    session.expect(timeout: 0) do |patterns|
      list = patterns
      patterns.on("ready", &callback)
      patterns.timeout { flunk "ready must match before timeout" }
    end
    assert_predicate list, :frozen?
    assert_predicate list.groups, :frozen?
    list.groups.each do |group|
      assert_predicate group, :frozen?
      assert group.all?(&:frozen?)
      assert group.last.all?(&:frozen?)
    end
    refute_predicate callback, :frozen?
    assert_raises(FrozenError) { list.on("later") }
    assert_raises(FrozenError) { list.eof }
    assert_raises(FrozenError) { list.timeout }
    assert_raises(NameError) { Expect::Pattern }
  end

  def test_callable_objects_work_for_both_log_targets
    receiver = Class.new do
      attr_reader :values

      def initialize = @values = []
      def call(value) = @values << value
    end
    log = receiver.new
    diagnostics = receiver.new
    session, = pipe_session(debug_level: 2, diagnostic_output: diagnostics)
    session.log_output = log
    session.write_log("hello")
    session.buffer = "ready"
    session.expect("ready", timeout: 0)
    assert_equal ["hello"], log.values
    assert(diagnostics.values.any? { |event| event[:event] == :matched })
  end

  def test_spawn_preserves_single_string_shell_and_literal_argv_semantics
    Expect.spawn("printf FIRST; printf SECOND", raw_pty: true) do |session|
      assert session.expect("FIRSTSECOND", timeout: 2).matched?
    end
    text = "FIRST; printf SECOND"
    Expect.spawn(RbConfig.ruby, "-e", "print ARGV.fetch(0)", text, raw_pty: true) do |session|
      assert_equal text, session.expect(text, timeout: 2).match
    end
  end

  def test_data_construction_and_copy_interfaces_keep_snapshots_immutable
    text = +"ready"
    [Expect::Result.new(1, nil, text), Expect::Result[number: 1, match: text]].each do |result|
      assert_equal 1, result.number
      assert_predicate result.match, :frozen?
      assert_equal Expect::Result.members, result.members
      assert_equal "ready", result.to_h { |key, value| [key.to_s, value] }.fetch("match")
    end
    refute_predicate text, :frozen?
  end

  private

  def snapshot(session)
    [session.before, session.after, session.match, session.match_number, session.captures, session.error]
  end
end
