# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

desc "Check Ruby style and common mistakes"
task :lint do
  ruby "-S", "rubocop"
end

desc "Validate public API documentation, README versions and RBS signatures"
task :api do
  ruby "script/check_api.rb"
  ruby "-S", "rbs", "-I", "sig", "validate"
end

task default: %i[lint test api]

namespace :test do
  desc "Log in over SSH and verify multiple scripts and persisted logs (opt-in)"
  task :ssh do
    ruby "test/integration/ssh_scripts.rb"
  end

  desc "Log in over SSH and verify real PTY interact handoff (opt-in)"
  task :ssh_interact do
    ruby "examples/ssh_interact.rb", "--auto"
  end

  desc "Automatically log into local SSH and run read-only macOS checks"
  task :ssh_auto do
    ruby "examples/ssh_auto.rb", "--no-interact"
  end

  desc "Run the local two-terminal kibitz scenarios and save logs (no SSH required)"
  task :kibitz do
    ruby "examples/kibitz/test_kibitz.rb"
  end
end
