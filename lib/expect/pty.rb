# frozen_string_literal: true

# 提供明确的 Gem 加载入口，避免与 Ruby 标准库 expect.rb（IO#expect 扩展）同名冲突。
require_relative "../expect"
