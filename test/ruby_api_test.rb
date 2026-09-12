# frozen_string_literal: true

require_relative "test_helper"

class RubyAPITest < ExpectTest
  def test_result_uses_native_struct_conversion_and_pattern_matching
    session, = pipe_session
    session.buffer = "before value=42 after"
    session.expect(/value=(\d+)/, timeout: 0)
    result = session.last_result
    values = [1, nil, "value=42", "before ", " after", session, ["42"]]

    assert_equal values, result.to_a
    assert_equal values, result.deconstruct
    assert_equal values, Array(result)
    assert_equal ["42"], result.to_h.fetch(:captures)
    refute_respond_to result, :to_ary
    number, error, match, before, after, connection, captures = result.to_a
    assert_equal values, [number, error, match, before, after, connection, captures]
    assert_pattern { result => { number: 1, captures: ["42"] } }
  end

  def test_send_retains_ruby_reflection_and_write_sends_bytes
    client, server = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, server)
    Expect.open(client) do |session|
      session.buffer = "ready"
      assert_equal "ready", session.send(:buffer)
      assert_nil session.send(:timeout=, nil)
      assert_equal 3, session.send(:write, "abc")
      assert_equal("abc", bounded { server.read(3) })
    end
  end

  def test_concise_expect_dsl_drives_a_dialogue_without_a_result_object
    session = child('print "name: "; puts "hello " + gets.strip', raw_pty: true)
    name = "Ruby"
    matched = session.expect(timeout: 2) do
      on("name: ") do |connection|
        connection.puts(name)
        connection.continue
      end
      on(/hello (\w+)/)
    end
    assert_equal 2, matched
    assert_equal "hello Ruby", session.match
    assert_equal ["Ruby"], session.captures
    assert_equal 0, session.wait(timeout: 1).exitstatus
  end

  def test_concise_dsl_supports_events_multi_session_and_result_objects
    first, writer = pipe_session
    second, = pipe_session
    writer.close
    ended = []
    timed_out = []
    result = Expect.expect_result(timeout: 0.02) do
      eof(from: first) do |connection|
        ended << connection
        connection.continue(reset_timeout: false)
      end
      on("missing", from: second)
      timeout { |sessions| timed_out.concat(sessions) }
    end
    assert result.timeout?
    assert_equal [first], ended
    assert_equal [second], timed_out
    assert_same second, result.session
  end

  def test_explicit_block_parameter_preserves_the_callers_self
    session, = pipe_session
    session.buffer = "ready"
    owner = self
    matched = session.expect(timeout: 0) do |patterns|
      assert_same owner, self
      patterns.on("ready") { assert_same owner, self }
    end
    assert_equal 1, matched
  end

  def test_optional_block_parameter_still_receives_the_pattern_builder
    session, = pipe_session
    session.buffer = "ready"
    matched = session.expect(timeout: 0) { |patterns = nil| patterns.on("ready") }
    assert_equal 1, matched
  end

  def test_break_from_a_concise_definition_does_not_consume_input
    session, writer = pipe_session
    writer.write("ready")
    result = session.expect(timeout: 0) do
      on("ready")
      break :cancelled
    end
    assert_equal :cancelled, result
    assert_nil session.last_result
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  def test_exception_in_a_concise_definition_does_not_consume_input
    session, writer = pipe_session
    writer.write("ready")
    assert_raises(RuntimeError) do
      session.expect(timeout: 0) do
        on("ready")
        raise "definition failed"
      end
    end
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  def test_block_patterns_drive_a_real_dialogue_with_captured_variables
    session = child(<<~'RUBY', raw_pty: true)
      print "name: "
      name = gets.strip
      print "code: "
      puts "hello #{name}:#{gets.strip}"
    RUBY
    name = "Ruby"
    result = session.expect_result(timeout: 2) do |patterns|
      patterns.on("name: ") do |connection|
        connection.puts(name)
        connection.continue
      end
      patterns.on("code: ") do |connection|
        connection.send_slow("123\n", delay: 0)
        connection.continue(reset_timeout: false)
      end
      patterns.on(/hello (\w+):(\d+)/)
    end

    assert_equal 3, result.number
    assert_equal %w[Ruby 123], result.captures
    assert_same session, result.session
    assert_equal 0, session.wait(timeout: 1).exitstatus
  end

  def test_keyword_timeout_and_default_timeout
    session, writer = pipe_session
    session.timeout = 0
    assert session.expect_result("missing").timeout?
    assert session.expect_result("missing", timeout: 0.01).timeout?
    background do
      sleep 0.02
      writer.write("ready")
    end
    assert_equal(1, bounded { session.expect("ready", timeout: nil) })
    assert_equal 0, session.timeout
  end

  def test_block_uses_keyword_timeout_and_returns_pattern_number
    session, = pipe_session
    session.buffer = "ready"
    number = session.expect(timeout: 0) { |patterns| patterns.on("ready") }
    assert_equal 1, number
  end

  def test_literal_patterns_are_unambiguous_even_with_callbacks
    %w[-i -ex -unknown timeout eof a.c].each do |literal|
      session, = pipe_session
      session.buffer = "prefix #{literal} suffix"
      observed = nil
      result = session.expect_result(timeout: 0) do |patterns|
        patterns.on(literal) { |connection| observed = connection.match }
      end
      assert result.matched?, literal
      assert_equal literal, observed
      assert_equal "prefix ", result.before
      assert_equal " suffix", session.buffer
    end
  end

  def test_positional_strings_are_literal_and_do_not_parse_command_line_flags
    %w[-i -ex -re timeout eof].each do |literal|
      session, = pipe_session
      session.buffer = "before #{literal} after"
      result = session.expect_result(literal, timeout: 0)
      assert result.matched?
      assert_equal literal, result.match
      assert_equal " after", session.buffer
    end
  end

  def test_duplicate_timeout_callbacks_are_rejected_before_reading
    session, writer = pipe_session
    writer.write("ready")
    assert_raises(ArgumentError) do
      session.expect(timeout: 0) do
        timeout { nil }
        timeout { nil }
      end
    end
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  def test_timeout_callback_receives_all_active_sessions
    first, = pipe_session
    second, = pipe_session
    observed = nil
    Expect.expect(timeout: 0) do
      on("first", from: first)
      on("second", from: second)
      timeout { |sessions| observed = sessions }
    end
    assert_equal [first, second], observed
  end

  def test_patterns_keep_declaration_priority
    session, = pipe_session
    session.buffer = "second first"
    result = session.expect_result(timeout: 0) do |patterns|
      patterns.on("first")
      patterns.on("second")
    end
    assert_equal 1, result.number
    assert_equal "second ", result.before
  end

  def test_invalid_patterns_and_positional_timeouts_do_not_consume_input
    session, writer = pipe_session
    writer.write("ready")
    [nil, 0].each do |timeout|
      assert_raises(ArgumentError) { session.expect(timeout, "ready", timeout: 1) }
      assert_raises(ArgumentError) { Expect.expect(timeout, "-i", session, "ready", timeout: 1) }
    end
    assert_raises(ArgumentError) { session.expect("ready", timeout: 0) { |patterns| patterns.on("ready") } }
    assert_raises(ArgumentError) { session.expect(timeout: 0) { |patterns| patterns.on(:eof) } }
    assert_raises(ArgumentError) { session.expect(timeout: 0) { |patterns| patterns.on("ready", from: []) } }
    assert_raises(ArgumentError) { Expect.expect(timeout: 0) { |patterns| patterns.on("ready") } }
    assert_raises(ArgumentError) { Expect.expect(timeout: 0) { |patterns| patterns.timeout { nil } } }
    assert_raises(ArgumentError) { session.expect(timeout: -1) { flunk "invalid timeout must fail before the block" } }
    assert_empty session.buffer
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  def test_definition_exception_does_not_run_callbacks_or_consume_input
    session, writer = pipe_session
    writer.write("ready")
    assert_raises(RuntimeError) do
      session.expect(timeout: 0) do |patterns|
        patterns.on("ready") { flunk "callbacks must wait until configuration finishes" }
        raise "configuration failed"
      end
    end
    assert_nil session.last_result
    assert_equal "ready", session.to_io.read_nonblock(5)
  end

  def test_callback_exception_preserves_the_match_and_unread_buffer
    session, = pipe_session
    session.buffer = "ready tail"
    error = assert_raises(RuntimeError) do
      session.expect(timeout: 0) do |patterns|
        patterns.on("ready") { raise "callback failed" }
      end
    end
    assert_equal "callback failed", error.message
    assert_equal "ready", session.match
    assert_equal " tail", session.buffer
  end

  def test_timeout_callback_can_continue_with_active_sessions
    session, = pipe_session
    observed = nil
    result = session.expect_result(timeout: 0) do |patterns|
      patterns.on("ready")
      patterns.timeout do |sessions|
        observed = sessions
        session.buffer = "ready"
        Expect.continue
      end
    end
    assert_equal [session], observed
    assert_equal 1, result.number
  end

  def test_continuation_without_reset_observes_the_deadline
    session, = pipe_session
    session.buffer = "ready"
    result = bounded(1) do
      session.expect_result(timeout: 0.01) do |patterns|
        patterns.on(/(?=ready)/) { Expect.continue(reset_timeout: false) }
      end
    end
    assert result.timeout?
    assert_equal "ready", session.buffer
  end

  def test_eof_block_receives_the_session_and_remaining_bytes
    session, writer = pipe_session
    writer.write("tail")
    writer.close
    observed = nil
    result = session.expect_result(timeout: 1) do |patterns|
      patterns.eof { |connection| observed = [connection, connection.before] }
    end
    assert result.eof?
    assert_equal [session, "tail"], observed
    assert_empty session.buffer
  end

  def test_class_block_routes_patterns_to_multiple_sessions
    first, = pipe_session
    second, writer = pipe_session
    writer.write("ready:42")
    result = Expect.expect_result(timeout: 1) do |patterns|
      patterns.on("missing", from: first)
      patterns.on(/ready:(\d+)/, from: [first, second])
    end
    assert_equal 2, result.number
    assert_same second, result.session
    assert_equal ["42"], result.captures
  end

  def test_class_keyword_from_selects_a_session
    session, writer = pipe_session
    writer.write("ready")
    assert_equal 1, Expect.expect("ready", from: session, timeout: 1)
  end

  def test_eof_continuation_keeps_other_sessions_active
    first, first_writer = pipe_session
    second, second_writer = pipe_session
    first_writer.close
    background do
      sleep 0.03
      second_writer.write("ready")
    end
    observed = []
    result = Expect.expect_result(timeout: 1) do |patterns|
      patterns.eof(from: first) do |connection|
        observed << connection
        connection.continue(reset_timeout: false)
      end
      patterns.on("ready", from: second)
    end
    assert_equal [first], observed
    assert_same second, result.session
    assert_equal 2, result.number
  end

  def test_timeout_before_class_patterns_receives_active_sessions
    session, = pipe_session
    observed = nil
    result = Expect.expect_result(timeout: 0) do |patterns|
      patterns.timeout { |sessions| observed = sessions }
      patterns.on("missing", from: session)
    end
    assert result.timeout?
    assert_equal [session], observed
  end

  def test_open_returns_block_value_and_preserves_borrowed_io
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    connection = nil
    result = Expect.open(reader) do |session|
      connection = session
      :finished
    end
    assert_equal :finished, result
    assert connection.closed?
    refute reader.closed?
    refute writer.closed?
  end

  def test_open_closes_both_owned_handles_on_exception
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    assert_raises(RuntimeError) do
      Expect.open(reader, writer: writer, own: true) { raise "stop" }
    end
    assert reader.closed?
    assert writer.closed?
  end

  def test_invalid_open_options_close_owned_io_and_preserve_borrowed_io
    [false, true].each do |own|
      reader, writer = IO.pipe
      @ios.push(reader, writer)
      assert_raises(ArgumentError) do
        Expect.open(reader, writer: writer, own: own, unknown: true) { flunk "invalid options" }
      end
      assert_equal own, reader.closed?
      assert_equal own, writer.closed?
    end
  end

  def test_boolean_predicates_use_ruby_truthiness_and_have_no_write_arguments
    session, = pipe_session
    refute session.log_stdout?
    session.log_stdout = true
    assert session.log_stdout?
    session.log_stdout = 0
    assert session.log_stdout?
    session.log_stdout = nil
    refute session.log_stdout?
    assert_raises(ArgumentError) { session.log_stdout?(true) }
  end

  def test_readiness_accepts_an_empty_group_with_a_keyword_timeout
    assert_empty Expect.readable_sessions(timeout: 0)
  end

  def test_spawn_closes_on_nonlocal_block_exit
    connection = nil
    result = Expect.spawn(RbConfig.ruby, "--disable-gems", "-e", "sleep 60", log_stdout: false) do |session|
      connection = session
      break :finished
    end
    assert_equal :finished, result
    assert connection.closed?
    refute connection.alive?
  end

  def test_buffer_setter_copies_bytes_and_applies_the_limit
    session, = pipe_session(buffer_limit: 4)
    value = +"before tail"
    session.buffer = value
    value.replace("changed")
    session.buffer.clear
    assert_equal "tail", session.buffer
    assert_equal Encoding::BINARY, session.buffer.encoding
    assert_equal "tail", session.clear_buffer
    assert_empty session.buffer
    assert_raises(ArgumentError) { session.buffer = nil }
  end

  def test_listeners_setter_takes_a_snapshot_and_validates_before_replacement
    session, writer = pipe_session
    output = StringIO.new
    listeners = [output]
    session.listeners = listeners
    listeners.clear
    session.listeners.clear
    assert_raises(ArgumentError) { session.listeners = [Object.new] }
    writer.write("ready")
    session.expect("ready", timeout: 1)
    assert_equal "ready", output.string
    session.listeners = []
    assert_empty session.listeners
  end

  def test_log_block_and_setter_receive_only_read_bytes
    session, writer = pipe_session
    chunks = []
    session.log_to { |bytes| chunks << bytes }
    assert_raises(ArgumentError) { session.log_to(StringIO.new) { nil } }
    writer.write("first")
    session.expect("first", timeout: 1)
    output = StringIO.new
    session.log_output = output
    writer.write("second")
    session.expect("second", timeout: 1)
    session.log_output = nil
    assert_equal "first", chunks.join
    assert_equal "second", output.string
    refute output.closed?
  end

  def test_puts_matches_standard_ruby_io_for_nested_and_recursive_arrays
    client, server = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, server)
    recursive = ["once"]
    recursive << recursive
    values = [nil, 42, "中文", "already\n", ["nested", ["last"]], recursive, "\xff".b]
    expected = StringIO.new("".b)
    expected.puts
    expected.puts(*values)
    Expect.open(client) do |session|
      assert_nil session.puts
      assert_nil session.puts(*values)
    end
    assert_equal(expected.string, bounded { server.read(expected.string.bytesize) })
  end

  def test_assigning_the_current_log_preserves_file_ownership
    session, = pipe_session
    Dir.mktmpdir do |directory|
      log = session.log_to(File.join(directory, "session.log"))
      session.log_output = log
      session.close
      assert log.closed?
    end
  end

  def test_write_converts_objects_and_append_returns_the_session
    client, server = Socket.pair(:UNIX, :STREAM, 0)
    @ios.push(client, server)
    values = [nil, 42, %w[a b]]
    expected = StringIO.new
    count = expected.write(*values)
    Expect.open(client) do |session|
      assert_equal count, session.write(*values)
      assert_same session, session << "tail" << "\n"
    end
    expected << "tail\n"
    assert_equal(expected.string, bounded { server.read(expected.string.bytesize) })
  end

  def test_sequence_block_filters_escape_and_keeps_trailing_bytes
    session, writer = pipe_session
    output = StringIO.new
    session.listeners = [output]
    observed = []
    value = :done
    session.on_sequence("STOP") do
      observed << value
      false
    end
    writer.write("beforeSTOPafter")
    assert_same session, Expect.interconnect(session, timeout: 1)
    assert_equal [:done], observed
    assert_equal "before", output.string
    assert_equal "after", session.buffer
  end
end
