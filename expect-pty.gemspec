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
    "lib/**/*.rb", "examples/**/*.rb", "examples/**/*.md", "docs/**/*.md",
    "test/**/*.rb", "test/**/*.sh", "test/**/*.md", "Gemfile", "Rakefile",
    ".rubocop.yml", "expect-pty.gemspec", "README.md", "LICENSE", "CHANGELOG.md", "script/ci"
  ]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
end
