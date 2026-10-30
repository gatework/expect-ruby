# frozen_string_literal: true

require_relative "test_helper"
require "pp"

class SnapshotBoundariesTest < ExpectTest
  def test_result_constructors_detach_text_behavior_and_preserve_bytes_and_encoding
    ["wireless 无线", "\xFF".b, "\xE9".dup.force_encoding(Encoding::ISO_8859_1)].each do |text|
      source = decorated(text)
      captures = [source, nil]
      def captures.map = self
      original = Expect::Result.new(status: :matched, match_number: 1, match: source, captures:)
      results = [original, Expect::Result[:matched, 1, nil, source], original.with(before: source)]
      results.each do |result|
        assert_instance_of String, result.match
        assert_equal text.bytes, result.match.bytes
        assert_equal text.encoding, result.match.encoding
        assert_empty result.match.instance_variables
        assert_predicate result.match, :frozen?
      end
      assert_equal [text, nil], original.captures
      refute_same captures, original.captures
      assert_predicate original.captures.first, :frozen?
      refute_predicate captures, :frozen?
      refute_predicate source, :frozen?
    end
  end

  def test_pretty_print_uses_the_summary_without_visiting_borrowed_objects
    error = IOError.new("synthetic-error-secret")
    source = Object.new
    [error, source].each do |value|
      value.define_singleton_method(:pretty_print) { |_| raise "borrowed object visited" }
    end
    results = [Expect::Result.new(status: :matched, match_number: 1, match: "synthetic-secret", captures: ["secret"]),
               Expect::Result.new(status: :error, before: "synthetic-secret", error:, session: source),
               Expect::Result.new(status: :eof, before: "synthetic-secret"),
               Expect::Result.new(status: :timeout, before: "synthetic-secret")]
    results.each { |result| assert_equal "#{result.inspect}\n", PP.pp(result, +"") }
    assert_same error, results[1].error
    assert_same source, results[1].session
  end

  def test_frozen_text_does_not_export_private_or_later_added_behavior
    extension = Module.new
    source = +"fact"
    source.extend(extension)
    source.define_singleton_method(:hidden_state) { [] }
    source.singleton_class.send(:private, :hidden_state)
    source.freeze
    result = Expect::Result.new(status: :matched, match_number: 1, match: source)
    extension.define_method(:external_state) { [] }
    assert_equal "fact", result.match
    refute result.match.respond_to?(:hidden_state, true)
    refute result.match.respond_to?(:external_state)
    refute_same source, result.match
  end

  def test_buffer_and_literal_patterns_do_not_borrow_or_freeze_caller_text
    session, = pipe_session
    buffer = decorated("ready")
    session.buffer = buffer
    buffer.replace("changed")
    assert_equal "ready", session.buffer
    pattern = decorated("ready")
    list = Expect::PatternList.new([session], [pattern])
    refute_predicate pattern, :frozen?
    pattern.replace("changed")
    assert_equal "ready", list.groups.first.last.first.value
    assert_instance_of String, list.groups.first.last.first.value
  end

  def test_response_escape_and_redaction_rules_are_independent_plain_bytes
    session, = pipe_session
    pattern, reply, escape, secret, replacement = %w[Prompt reply STOP secret MASK].map { |value| decorated(value) }
    responder = Expect::Responder.new.on(pattern, reply:)
    session.on_sequence(escape)
    filter = Expect::Redactor.new([secret], replacement:)
    session.redact(secret)
    [pattern, reply, escape, secret, replacement].each do |value|
      refute_predicate value, :frozen?
      value.replace("changed")
    end
    assert_equal "MASK!", filter.append("secret!") + filter.finish
    assert_equal ["STOP"], session.sequences.keys
    input, output = IO.pipe
    @ios.push(input, output)
    target, = pipe_session(writer: output)
    target.buffer = "Prompt DONE"
    assert responder.expect(target, "DONE", timeout: 1).matched?
    assert_equal("reply", bounded { input.read(5) })
  end

  def test_writes_convert_each_object_once_then_copy_its_bytes_before_callbacks
    input, output = IO.pipe
    @ios.push(input, output)
    source = decorated("\xFFabc".b)
    calls = 0
    source.define_singleton_method(:to_s) do
      calls += 1
      self
    end
    source.define_singleton_method(:b) { "incorrect" }
    logger = diagnostic_logger { source.replace("changed") }
    transcript = StringIO.new
    session, = pipe_session(writer: output, logger:, transcript:)
    assert_equal 4, session.write(source)
    assert_equal("\xFFabc".b, bounded { input.read(4) })
    assert_equal 1, calls
    session.write_transcript(source)
    assert_equal "changed", transcript.string
    assert_equal 2, calls
  end

  def test_spawn_executes_the_same_argument_snapshot_that_it_publishes
    argument = +"original"
    type = Class.new(Expect::Session) do
      define_method(:exec_child) do |command, **options|
        argument.replace("changed")
        super(command, **options)
      end
    end
    session = type.new
    @sessions << session
    session.spawn(RbConfig.ruby, "--disable-gems", "-e", "print ARGV.fetch(0)", argument, raw: true)
    assert_equal "original", session.command.last
    assert_equal "original", session.expect(:eof, timeout: 3).before
    refute_predicate argument, :frozen?
  end

  def test_redactor_pass_through_returns_independent_plain_bytes
    input = decorated("public")
    output = Expect::Redactor.new([]).append(input)
    input.replace("changed")
    assert_equal "public", output
    assert_instance_of String, output
    assert_empty output.instance_variables
  end

  def test_rule_validation_uses_copied_bytes_and_preserves_existing_rules_on_failure
    empty = decorated("")
    def empty.empty? = false
    filter = Expect::Redactor.new(["secret"])
    assert_raises(ArgumentError) { filter.patterns = [empty] }
    assert_equal "[FILTERED]", filter.append("secret") + filter.finish
    assert_raises(ArgumentError) { Expect::Redactor.new([], replacement: empty) }
    assert_raises(ArgumentError) { Expect::Responder.new.on(empty, reply: "yes") }
    session, = pipe_session
    assert_raises(ArgumentError) { session.redact(empty) }
    assert_raises(ArgumentError) { session.on_sequence(empty) }
    refute_predicate empty, :frozen?
  end

  def test_invalid_spawn_bytes_fail_before_terminal_state_changes
    argument = decorated("bad\0argument")
    def argument.include?(_) = false
    session = Expect::Session.new
    @sessions << session
    mode = terminal_configuration(session)
    assert_raises(ArgumentError) { session.spawn(argument, raw: true) }
    assert_equal mode, terminal_configuration(session)
    assert_nil session.command
    assert_nil session.pid
    refute_predicate argument, :frozen?
  end

  private

  def decorated(text)
    Class.new(String).new(text).tap do |value|
      value.instance_variable_set(:@metadata, [])
      def value.b = self
      def value.dup = self
    end
  end
end
