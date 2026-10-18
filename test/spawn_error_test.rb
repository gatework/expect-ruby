# frozen_string_literal: true

require_relative "test_helper"

class SpawnErrorTest < ExpectTest
  def test_missing_program_retains_system_error_cause
    error = assert_raises(Expect::SpawnError) { Expect.spawn("/no/such/expect-error-program") }
    assert_equal Errno::ENOENT::Errno, error.errno
    assert_instance_of Errno::ENOENT, error.cause
  end

  def test_permission_error_retains_errno
    Dir.mktmpdir do |directory|
      program = File.join(directory, "not-executable")
      File.write(program, "not executable")
      File.chmod(0o600, program)
      error = assert_raises(Expect::SpawnError) { Expect.spawn(program) }
      assert_equal Errno::EACCES::Errno, error.errno
      assert_instance_of Errno::EACCES, error.cause
    end
  end

  def test_directory_error_is_not_lost
    error = assert_raises(Expect::SpawnError) { Expect.spawn("cat", chdir: "/no/such/expect-directory") }
    assert_equal Errno::ENOENT::Errno, error.errno
    assert_instance_of Errno::ENOENT, error.cause
  end

  def test_invalid_path_bytes_still_report_startup_failure
    error = assert_raises(Expect::SpawnError) { Expect.spawn("cat", chdir: "/no/such/\xff".b) }
    assert_equal Errno::ENOENT::Errno, error.errno
    assert_instance_of Errno::ENOENT, error.cause
  end

  def test_non_system_error_has_a_safe_cause_without_an_errno
    error = assert_raises(Expect::SpawnError) { Expect.spawn("cat", env: { "VALUE" => Object.new }) }
    assert_nil error.errno
    assert_kind_of StandardError, error.cause
    assert_match(/TypeError/, error.message)
  end
end
