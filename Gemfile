# frozen_string_literal: true

source "https://rubygems.org"
gemspec

group :development, :test do
  gem "minitest", "~> 5.0", require: false
  # RuboCop 的依赖也必须支持最低 Ruby 版本。
  gem "parallel", "~> 1.27", require: false
  gem "rake", "~> 13.0", require: false
  gem "rubocop", "~> 1.89", require: false

  # 测试、示例和发布工具直接使用的标准库 gem，不依赖其他开发工具间接引入。
  gem "digest", require: false
  gem "etc", require: false
  gem "fileutils", require: false
  gem "json", require: false
  gem "net-http", require: false
  gem "open3", require: false
  gem "optparse", require: false
  gem "securerandom", require: false
  gem "tempfile", require: false
  gem "time", require: false
  gem "timeout", require: false
  gem "tmpdir", require: false
end
