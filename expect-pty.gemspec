# frozen_string_literal: true

require_relative "lib/expect/version"

Gem::Specification.new do |spec|
  spec.name = "expect-pty"
  spec.version = Expect::VERSION
  spec.authors = ["expect-pty contributors"]
  spec.homepage = "https://github.com/gatework/expect-ruby"
  spec.summary = "Ruby PTY automation with the Expect.pm interaction model"
  spec.description = "Automate interactive programs with exact and regexp matching, " \
                     "Ruby blocks, multi-session waits, logging and terminal interaction."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir[
    "lib/**/*.rb", "examples/**/*.rb", "examples/**/*.md", "docs/**/*.md", "benchmark/**/*.rb",
    "test/**/*.rb", "test/**/*.sh", "test/**/*.md", "Gemfile", "Rakefile",
    ".rubocop.yml", "expect-pty.gemspec", "README.md", "CONTRIBUTING.md", "LICENSE", "CHANGELOG.md",
    "script/ci", "script/release.rb"
  ]
  spec.require_paths = ["lib"]
  # 显式声明可独立升级的标准库 gem，供应用的 Bundler 解析完整运行时依赖。
  # pty 是 Ruby 自带的 POSIX 扩展，不是独立 gem。
  spec.add_dependency "forwardable", "~> 1.3"
  spec.add_dependency "io-console", ">= 0.6", "< 1.0"
  spec.add_dependency "io-wait", ">= 0.3", "< 1.0"
  spec.add_dependency "shellwords", ">= 0.1", "< 1.0"
  spec.add_dependency "stringio", "~> 3.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
end
