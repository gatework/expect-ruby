# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class EntrypointTest < ExpectTest
  def test_standard_library_expect_is_not_shadowed
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
                                     'require "expect"; abort "missing IO#expect" unless IO.method_defined?(:expect)')
    assert status.success?, output
  end

  def test_both_entrypoint_orders_keep_standard_and_pty_apis
    [%w[expect expect/pty], %w[expect/pty expect]].each do |order|
      code = 'ARGV.each { |path| require path }; abort "missing IO#expect" unless IO.method_defined?(:expect); ' \
             'abort "missing PTY API" unless Expect.respond_to?(:spawn)'
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code, *order)
      assert status.success?, output
    end
  end
end
