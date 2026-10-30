# frozen_string_literal: true

require "yard"
require "rbs"
require_relative "../lib/expect/pty"

# 从真实方法查找链校验接口；YARD 标记的内部协议不属于发布契约。
module APICheck
  ROOT = Pathname(__dir__).parent.freeze
  TYPES = [Expect, Expect::Session, Expect::Result, Expect::PatternList,
           Expect::Redactor, Expect::WriteTimeout, Expect::Responder].freeze
  DATA_METHODS = %i[members with to_h deconstruct deconstruct_keys].freeze

  # 逐个核对公开类型的文档与签名；任一缺口直接报错，全部通过后才输出成功提示。
  def self.run
    builder = prepare
    TYPES.each { |type| validate_type!(type, builder) }
    puts "Public API documentation and RBS coverage passed"
  end

  # 清空旧 YARD 注册表并重读库源码，解析 RBS 类型名称，返回供本轮校验共用的定义构建器。
  def self.prepare
    YARD::Registry.clear
    YARD.parse(Dir[ROOT.join("lib/**/*.rb").to_s])
    loader = RBS::EnvironmentLoader.new
    loader.add(path: ROOT.join("sig"))
    RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
  end

  # 校验本类型及其混入模块提供的公开方法，排除基类继承方法；Data 的生成接口单独纳入。
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

  # 按实际方法所有者查找文档；仅显式标记 @api private 的内部协议可跳过公开签名检查。
  def self.validate_methods!(type, methods, separator, definition)
    methods.each do |method|
      path = "#{type}#{separator}#{method}"
      owner = separator == "#" ? type.instance_method(method).owner : type.method(method).owner
      object = YARD::Registry.at(path) || YARD::Registry.at("#{owner.name}#{separator}#{method}")
      next if object&.tag(:api)&.text == "private"

      raise "Undocumented public API: #{path}" unless object && !object.docstring.empty?

      validate_declaration!(type, method, path, owner, definition)
    end
    validate_existing_methods!(type, separator, definition)
  end

  def self.validate_existing_methods!(type, separator, definition)
    # 反向检查仅属于当前类型的声明，防止已移除接口继续留在消费者签名中。
    definition.methods.each do |method, declaration|
      next unless declaration.defined_in.to_s == "::#{type}"

      available = if separator == "." then type.respond_to?(method)
                  else method == :initialize || type.public_method_defined?(method)
                  end
      next if available

      raise "Stale public RBS declaration: #{type}#{separator}#{method}"
    end
  end

  def self.validate_declaration!(type, method, path, owner, definition)
    # 不能用 Data.new 等基类占位声明冒充具体接口；模块声明由解析后的类型查找链确认。
    declared_in = definition.methods[method]&.defined_in&.to_s
    allowed = ["::#{type}"]
    allowed << "::#{owner.name}" if owner.name && !(type == Expect::Result && DATA_METHODS.include?(method))
    raise "Missing public RBS declaration: #{path}" unless allowed.include?(declared_in)
  end
end

APICheck.run if $PROGRAM_NAME == __FILE__
