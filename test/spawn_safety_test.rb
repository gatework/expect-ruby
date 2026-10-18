# frozen_string_literal: true

require_relative "test_helper"

class SpawnSafetyTest < ExpectTest
  def test_single_string_does_not_invoke_a_shell
    assert_raises(Expect::SpawnError) do
      Expect.spawn("echo A; echo B") { |session| session.expect(:eof, timeout: 2) }
    end
  end

  def test_shell_execution_is_explicit
    Expect.spawn("printf A; printf B", shell: true, raw: true) do |session|
      assert_equal "AB", session.expect(:eof, timeout: 2).before
    end
  end

  def test_single_executable_filename_is_literal_even_with_shell_characters
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "program ; literal")
      File.write(executable, "#!/bin/sh\nprintf LITERAL\n")
      File.chmod(0o700, executable)
      Expect.spawn(executable, raw: true) do |session|
        assert_equal "LITERAL", session.expect(:eof, timeout: 2).before
      end
    end
  end

  def test_shell_rejects_multiple_arguments_before_starting_a_process
    session = Expect::Session.new
    @sessions << session
    assert_raises(ArgumentError) { session.spawn("echo", "A", shell: true) }
    assert_nil session.pid
    assert_nil session.command
  end
end
