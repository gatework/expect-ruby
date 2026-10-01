# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require_relative "../script/check_api"

class APICheckTest < ExpectTest
  def test_standalone_check_works_outside_the_project_root
    script = File.expand_path("../script/check_api.rb", __dir__)
    Dir.mktmpdir("expect-api-check") do |directory|
      [File.dirname(script), directory].each do |working_directory|
        output, errors, status = Open3.capture3(
          { "RUBYOPT" => nil, "BUNDLER_SETUP" => nil }, RbConfig.ruby, script, chdir: working_directory
        )
        assert status.success?, "#{working_directory}: #{output}\n#{errors}"
        assert_includes output, "Public API documentation and RBS coverage passed"
        refute_includes errors, "io-wait gem is deprecated"
      end
    end
  end

  def test_included_public_methods_cannot_escape_documentation_or_signature_checks
    extension = Module.new { def undocumented_api = nil }
    Expect::Session.include(extension)
    builder = APICheck.prepare
    error = assert_raises(RuntimeError) { APICheck.validate_type!(Expect::Session, builder) }
    assert_includes error.message, "Undocumented public API: Expect::Session#undocumented_api"

    object = YARD::CodeObjects::MethodObject.new(YARD::Registry.at("Expect::Session"), :undocumented_api)
    object.docstring = "A documented method still needs a signature."
    error = assert_raises(RuntimeError) { APICheck.validate_type!(Expect::Session, builder) }
    assert_includes error.message, "Missing public RBS declaration: Expect::Session#undocumented_api"
  ensure
    extension&.module_eval { remove_method :undocumented_api }
  end

  def test_documented_internal_protocol_does_not_need_a_public_signature
    extension = Module.new { def internal_protocol = nil }
    Expect::Session.include(extension)
    builder = APICheck.prepare
    object = YARD::CodeObjects::MethodObject.new(YARD::Registry.at("Expect::Session"), :internal_protocol)
    object.docstring = "A collaborator-only protocol."
    object.add_tag(YARD::Tags::Tag.new(:api, "private"))
    APICheck.validate_type!(Expect::Session, builder)
  ensure
    extension&.module_eval { remove_method :internal_protocol }
  end

  def test_result_constructors_have_concrete_signatures_and_are_checked
    builder = APICheck.prepare
    definition = builder.build_singleton(RBS::TypeName.parse("::Expect::Result"))
    %i[new []].each do |method|
      types = definition.methods.fetch(method).method_types
      assert_equal 2, types.size
      assert(types.all? { |type| type.type.return_type.to_s == "::Expect::Result" })
    end
    definition.methods.delete(:new)
    error = assert_raises(RuntimeError) { APICheck.validate_type!(Expect::Result, builder) }
    assert_includes error.message, "Missing public RBS declaration: Expect::Result.new"
  end

  def test_data_interfaces_and_logger_protocol_are_declared
    builder = APICheck.prepare
    APICheck.validate_type!(Expect::Result, builder)
    %w[_Logger].each do |name|
      definition = builder.build_interface(RBS::TypeName.parse("::Expect::#{name}"))
      assert definition.methods.key?(:add)
      assert definition.methods.key?(:debug?)
    end
  end
end
