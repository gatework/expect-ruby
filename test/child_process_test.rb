# frozen_string_literal: true

require_relative "test_helper"

class ChildProcessTest < ExpectTest
  def test_process_supervisor_uses_the_existing_resource_ledger
    reader, writer = IO.pipe
    @ios.push(reader, writer)
    resources = Expect.const_get(:ResourceOwner, false).new(reader, writer:, own: false)
    supervisor = Expect.const_get(:ChildProcess, false).new(resources)
    assert_nil supervisor.status
    assert_nil supervisor.wait(0)
    resources.pid = 123_456
    Process.stub(:waitpid2, lambda { |pid, _|
      assert_equal 123_456, pid
      [pid, :finished]
    }) do
      assert_equal :finished, supervisor.status
    end
    assert_nil resources.pid
  end
end
