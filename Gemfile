# frozen_string_literal: true

source "https://rubygems.org"
gemspec

group :development, :test do
  gem "minitest", "~> 5.0", require: false
  # 开发工具与最低 Ruby 3.4 同步验证。
  gem "irb", require: false # YARD 使用 irb/notifier，Ruby 4 不再默认提供。
  gem "parallel", "~> 1.27", require: false
  gem "rake", "~> 13.0", require: false
  gem "rbs", "~> 4.0", require: false
  gem "yard", "~> 0.9", require: false
  # 固定已审阅的规则集，避免不同 CI 环境自动启用新 cop 改变发布门槛。
  gem "rubocop", "= 1.89.0", require: false

  # 测试、示例和发布工具直接使用的标准库 gem，不依赖其他开发工具间接引入。
  gem "digest", require: false
  gem "etc", require: false
  gem "fileutils", require: false
  gem "json", require: false
  gem "logger", require: false
  gem "net-http", require: false
  gem "open3", require: false
  gem "optparse", require: false
  gem "securerandom", require: false
  gem "tempfile", require: false
  gem "time", require: false
  gem "timeout", require: false
  gem "tmpdir", require: false
end
