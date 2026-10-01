# frozen_string_literal: true

require "yard"
require "rbs"
require "pathname"
require_relative "../lib/expect"

# 从真实方法查找链校验接口；YARD 标记的内部协议不属于发布契约。
module APICheck
  ROOT = Pathname(__dir__).parent.freeze
  TYPES = [Expect, Expect::Session, Expect::Result, Expect::PatternList,
           Expect::Redactor, Expect::WriteTimeout].freeze
  DATA_METHODS = %i[members with to_h deconstruct deconstruct_keys].freeze

  def self.run
    builder = prepare
    TYPES.each { |type| validate_type!(type, builder) }
    puts "Public API documentation and RBS coverage passed"
  end

  def self.prepare
    YARD::Registry.clear
    YARD.parse(Dir[ROOT.join("lib/**/*.rb").to_s])
    loader = RBS::EnvironmentLoader.new
    loader.add(path: ROOT.join("sig"))
    RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
  end

  def self.validate_type!(type, builder)
    name = RBS::TypeName.parse("::#{type}")
    if type.is_a?(Class)
      inherited = type.superclass.ancestors
      methods = type.public_instance_methods.reject { |method| inherited.include?(type.instance_method(method).owner) }
      methods |= DATA_METHODS if type == Expect::Result
      methods |= [:initialize]
      validate_methods!(type, methods, "#", builder.build_instance(name))
    end

    inherited = type.is_a?(Class) ? type.superclass.singleton_class.ancestors : Module.ancestors
    methods = type.singleton_class.public_instance_methods.reject do |method|
      inherited.include?(type.method(method).owner)
    end
    validate_methods!(type, methods, ".", builder.build_singleton(name))
  end

  def self.validate_methods!(type, methods, separator, definition)
    methods.each do |method|
      path = "#{type}#{separator}#{method}"
      owner = separator == "#" ? type.instance_method(method).owner : type.method(method).owner
      object = YARD::Registry.at(path) || YARD::Registry.at("#{owner.name}#{separator}#{method}")
      next if object&.tag(:api)&.text == "private"

      raise "Undocumented public API: #{path}" unless object && !object.docstring.empty?

      validate_signature!(type, method, path, owner, definition)
    end
  end

  def self.validate_signature!(type, method, path, owner, definition)
    # 不能用 Data.new 等基类占位声明冒充具体接口；模块声明由解析后的类型查找链确认。
    declared_in = definition.methods[method]&.defined_in&.to_s
    allowed = ["::#{type}"]
    allowed << "::#{owner.name}" if owner.name && !(type == Expect::Result && DATA_METHODS.include?(method))
    raise "Missing public RBS declaration: #{path}" unless allowed.include?(declared_in)
  end
end

APICheck.run if $PROGRAM_NAME == __FILE__
