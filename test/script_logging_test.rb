# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/script_probe"
require "etc"

class ScriptLoggingTest < ExpectTest
  def shell_probe
    session = Expect.spawn("/bin/sh", "-i", env: { "PS1" => ScriptProbe::PROMPT, "ENV" => nil, "LC_ALL" => "C" },
                                            raw_pty: true, log_stdout: false, write_timeout: 3)
    @sessions << session
    ScriptProbe::Runner.new(session).ready!
  end

  def test_multiple_script_files_with_persisted_log_and_shutdown_drain
    runner = shell_probe
    Dir.mktmpdir do |dir|
      report = ScriptProbe.verify_file_session(runner, File.join(dir, "session.log"), user: Etc.getpwuid.name)
      assert_equal([0, 0, 0, 7, 0, 0, 0], report[:cases].map { |result| result[:status] })
      assert(report[:cases].all? { |result| result[:passed] })
      assert_operator report[:log_bytes], :>, 500
      assert_equal 10, report[:checks].length
    end
  end

  def test_callback_log_records_multiple_scripts_exactly_once
    runner = shell_probe
    chunks = []
    runner.session.log_to(->(bytes) { chunks << bytes.dup })
    %w[first second].each do |value|
      runner.run(value, "printf '#{value}\\n'\n", expected_status: 0, expected_output: "#{value}\n")
    end
    runner.finish!
    log = ScriptProbe.normalize(chunks.join)
    assert_equal 1, log.scan(/^first$/).length
    assert_equal 1, log.scan(/^second$/).length
    assert_operator log.index("[SEND] first"), :<, log.index("[SEND] second")
    assert_includes log, "SESSION_FINAL_TAIL\n"
  end

  def test_borrowed_log_is_flushed_and_stays_open_after_multiple_scripts
    runner = shell_probe
    Tempfile.create("expect-borrowed-log") do |file|
      runner.session.log_to(file)
      runner.run("one", "printf 'BORROWED_ONE\\n'", expected_status: 0, expected_output: "BORROWED_ONE\n")
      assert_includes File.binread(file.path), "BORROWED_ONE\n"
      runner.run("two", "printf 'BORROWED_TWO\\n'", expected_status: 0, expected_output: "BORROWED_TWO\n")
      runner.finish!
      refute file.closed?
      text = File.binread(file.path)
      assert_includes text, "BORROWED_TWO\n"
      assert_includes text, "SESSION_FINAL_TAIL\n"
    end
  end

  def test_nonzero_exit_is_reported_even_when_expected_text_appears
    runner = shell_probe
    failure = assert_raises(ScriptProbe::Failure) do
      runner.run("bad_status", "printf 'looks good\\n'; exit 9", expected_status: 0, expected_output: "looks good\n")
    end
    assert_match(/exit 9, expected 0/, failure.message)
    refute runner.results.last[:passed]
    result = runner.run("after_failure", "printf 'still alive\\n'", expected_status: 0,
                                                                    expected_output: "still alive\n")
    assert result[:passed]
  end

  def test_matching_output_is_required_even_with_zero_exit_status
    runner = shell_probe
    assert_raises(ScriptProbe::Failure) do
      runner.run("wrong_output", "printf 'actual\\n'", expected_status: 0, expected_output: "expected\n")
    end
    refute runner.results.last[:passed]
  end

  def test_script_arguments_preserve_quotes_and_shell_metacharacters
    runner = shell_probe
    result = runner.run("quoting", "printf '%s\\n' \"a'b\" '$(not-a-command)' 'semi;colon'\n",
                        expected_status: 0, expected_output: "a'b\n$(not-a-command)\nsemi;colon\n")
    assert result[:passed]
  end

  def test_crlf_terminal_output_preserves_exact_script_boundaries
    runner = shell_probe
    runner.session.write("stty opost onlcr\n")
    assert_equal 1, runner.session.expect(ScriptProbe::PROMPT, timeout: 2).number
    ["", "line\n", "no final newline", "two\n\n"].each do |output|
      result = runner.run("crlf", "printf %s #{Shellwords.escape(output)}",
                          expected_status: 0, expected_output: output)
      assert_equal output, result[:output]
    end
  end

  def test_logger_error_is_visible_to_caller
    runner = shell_probe
    runner.session.log_to(->(_) { raise IOError, "log destination failed" })
    error = assert_raises(IOError) do
      runner.run("logger_failure", "printf 'output\\n'", expected_status: 0, expected_output: "output\n")
    end
    assert_equal "log destination failed", error.message
    assert_empty runner.results
  end

  def test_timeout_preserves_log_and_subsequent_output_is_captured
    runner = shell_probe
    session = runner.session
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timeout.log")
      session.log_to(path, mode: "w")
      session.write("printf 'BEFORE_TIMEOUT\\n'; sleep 0.15; printf 'AFTER_TIMEOUT\\n'\n")
      assert_equal 1, session.expect("BEFORE_TIMEOUT\n", timeout: 2).number
      assert_nil session.expect("AFTER_TIMEOUT", timeout: 0.02).number
      assert_equal :timeout, session.error
      assert_includes File.binread(path), "BEFORE_TIMEOUT\n"
      assert_equal 1, session.expect("AFTER_TIMEOUT\n", timeout: 2).number
      assert_equal 1, session.expect(ScriptProbe::PROMPT, timeout: 2).number
      runner.finish!
      text = File.binread(path)
      assert_equal 1, text.scan("BEFORE_TIMEOUT\n").length
      assert_equal 1, text.scan("AFTER_TIMEOUT\n").length
      assert_includes text, "SESSION_FINAL_TAIL\n"
    end
  end
end
