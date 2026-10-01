# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../script/release"

class ReleaseTest < Minitest::Test
  def test_current_readme_installation_examples_use_the_current_version
    readme = File.read(File.expand_path("../README.md", __dir__))
    assert_nil Release.validate_readme!(readme, Expect::VERSION)
  end

  def test_readme_version_validation_rejects_stale_installation_examples
    Release.validate_readme!(%(gem "expect-pty", "~> 0.5.3"), "0.5.3")
    Release.validate_readme!("gem build --output tmp/expect-pty-0.5.3.gem", "0.5.3")
    assert_raises(RuntimeError) { Release.validate_readme!(%(gem "expect-pty", "~> 0.5.2"), "0.5.3") }
    assert_raises(RuntimeError) { Release.validate_readme!("gem install expect-pty-0.5.2.gem", "0.5.3") }
  end

  def test_package_contains_runtime_types_and_user_docs_without_development_material
    spec = Gem::Specification.load(File.expand_path("../expect-pty.gemspec", __dir__))
    %w[lib/expect/session.rb lib/expect/cleanup.rb sig/expect.rbs docs/API.md docs/MIGRATION.md].each do |path|
      assert_includes spec.files, path
    end
    assert_empty spec.files.grep(%r{\A(?:test/|benchmark/|examples/|script/|Gemfile|Rakefile|\.rubocop)})
    assert_equal Gem::Requirement.new(">= 3.4"), spec.required_ruby_version
  end

  def test_extracts_only_the_selected_version
    changelog = "# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-09-12\n\n- New API.\n\n## 0.1.1\n\n- Old API.\n"
    assert_equal "- New API.", Release.release_notes(changelog, "0.2.0")
  end

  def test_dry_run_writes_identical_utf8_notes_in_c_and_utf8_locales
    notes = "- 修复初始化中断，保留原异常。\n"
    with_package do |_release, artifact|
      script = locale_script
      File.write("CHANGELOG.md", "## #{Expect::VERSION}\n\n#{notes}", encoding: "UTF-8")
      rebuild_package
      %w[US-ASCII UTF-8].each do |encoding|
        env = release_environment.merge("LC_ALL" => (encoding == "US-ASCII" ? "C" : "en_US.UTF-8"), "LANG" => "C")
        output, error, status = Open3.capture3(env, RbConfig.ruby, "-E#{encoding}", script,
                                               "--dry-run", "--artifact", artifact, binmode: true)
        assert status.success?, "#{encoding}: #{output} #{error}"
        assert_includes output, "Dry run complete"
        files = Dir.glob("tmp/release/#{Expect::VERSION}/candidate-*/release-notes.md")
        refute_empty files
        files.each { |file| assert_equal notes.b, File.binread(file) }
      end
    end
  end

  def test_dry_run_rejects_invalid_utf8_without_rewriting_the_changelog
    with_package do |_release, artifact|
      script = locale_script
      bytes = "## #{Expect::VERSION}\n- invalid \xff\n".b
      File.binwrite("CHANGELOG.md", bytes)
      rebuild_package
      _output, error, status = Open3.capture3(release_environment.merge("LC_ALL" => "C", "LANG" => "C"),
                                              RbConfig.ruby, "-EUS-ASCII", script, "--dry-run", "--artifact", artifact)
      refute status.success?
      assert_includes error, "Invalid UTF-8 in CHANGELOG.md"
      assert_equal bytes, File.binread("CHANGELOG.md")
      assert_empty Dir.glob("tmp/release/#{Expect::VERSION}/candidate-*")
    end
  end

  def test_rejects_unreleased_missing_empty_or_invalid_versions
    ["## Unreleased\n- Pending.\n## 0.2.0\n- Ready.", "## 0.1.1\n- Old.", "## 0.2.0\n"].each do |changelog|
      assert_raises(RuntimeError) { Release.release_notes(changelog, "0.2.0") }
    end
    assert_raises(RuntimeError) { Release.release_notes("## 0.2.0.rc1\n- Preview.", "0.2.0.rc1") }
    assert_raises(RuntimeError) { Release.release_notes("## Unreleased \t\n- Pending.\n## 0.2.0\n- Ready.", "0.2.0") }
  end

  def test_dry_run_verifies_the_artifact_without_remote_calls
    with_package do |release, artifact|
      release.stub(:github, ->(*) { flunk "dry run contacted GitHub" }) do
        release.stub(:get, ->(*) { flunk "dry run contacted RubyGems" }) do
          capture_io { release.run }
        end
      end
      directory = Dir.glob(File.join("tmp", "release", Expect::VERSION, "candidate-*")).fetch(0)
      checksum = File.read(File.join(directory, "SHA256SUMS"))
      assert_equal "#{Digest::SHA256.file(artifact).hexdigest}  #{File.basename(artifact)}\n", checksum
      assert_equal "- Release fixture.\n", File.read(File.join(directory, "release-notes.md"))
      File.write(artifact, "another build")
      assert_equal checksum.split.first, Digest::SHA256.file(File.join(directory, File.basename(artifact))).hexdigest
    end
  end

  def test_rubygems_only_publishes_the_verified_copy_without_github
    with_package do |_release, artifact|
      commit_package_source
      release = Release.new(artifact:, rubygems_only: true)
      bytes = File.binread(artifact)
      checksum = Digest::SHA256.hexdigest(bytes)
      published = false
      get = lambda do |path|
        if path.start_with?("/downloads/")
          Struct.new(:code, :body).new("200", bytes)
        elsif published
          Struct.new(:code, :body).new("200", JSON.generate("sha" => checksum, "yanked" => false))
        else
          Struct.new(:code, :body).new("404", "")
        end
      end
      push = lambda do |*arguments|
        candidate = arguments.fetch(2)
        assert_equal ["gem", "push", candidate, "--host", "https://rubygems.org"], arguments
        assert_match %r{/tmp/release/#{Regexp.escape(Expect::VERSION)}/candidate-[^/]+/}, candidate
        assert_equal bytes, File.binread(candidate)
        refute_equal File.expand_path(artifact), candidate
        published = true
      end
      release.stub(:get, get) do
        release.stub(:system, push) do
          release.stub(:github, ->(*) { flunk "RubyGems-only release contacted GitHub" }) do
            release.stub(:publish_github, -> { flunk "RubyGems-only release published to GitHub" }) do
              [nil, "true"].each do |github_actions|
                with_environment("GITHUB_ACTIONS" => github_actions,
                                 "GEM_HOST_API_KEY" => (github_actions ? "test-only-api-key" : nil)) do
                  published = false
                  output, = capture_io { release.run }
                  assert_includes output, "SHA256 verified"
                  assert published
                end
              end
            end
          end
        end
      end
    end
  end

  def test_ci_publish_requires_an_api_key_before_pushing
    release = Release.new(rubygems_only: true)
    release.stub(:registry_version, nil) do
      release.stub(:system, ->(*) { flunk "pushed without a CI API key" }) do
        [nil, ""].each do |api_key|
          with_environment("GITHUB_ACTIONS" => "true", "GEM_HOST_API_KEY" => api_key) do
            error = assert_raises(RuntimeError) { release.send(:publish_rubygems) }
            assert_includes error.message, "RUBYGEMS_API_KEY"
          end
        end
      end
    end
  end

  def test_rubygems_only_rejects_uncommitted_source_before_publishing
    with_package do |_release, artifact|
      release = Release.new(artifact:, rubygems_only: true)
      release.stub(:capture, " M payload.rb") do
        release.stub(:get, ->(*) { flunk "uncommitted source contacted RubyGems" }) do
          assert_match "Commit all source changes", assert_raises(RuntimeError) { release.run }.message
        end
      end
    end
  end

  def test_rubygems_only_rechecks_source_after_verification
    with_package do |_release, artifact|
      commit_package_source
      release = Release.new(artifact:, rubygems_only: true)
      statuses = ["", " M payload.rb"]
      original = release.method(:capture)
      capture = ->(*arguments) { arguments.include?("rev-parse") ? original.call(*arguments) : statuses.shift }
      release.stub(:capture, capture) do
        release.stub(:get, ->(*) { flunk "changed source contacted RubyGems" }) do
          capture_io do
            assert_match "Source changed", assert_raises(RuntimeError) { release.run }.message
          end
        end
      end
    end
  end

  def test_rejects_a_package_from_different_source
    with_package do |release, _artifact|
      File.write("payload.rb", "puts :changed\n")
      assert_match "Artifact differs from source", assert_raises(RuntimeError) { release.send(:verify_package) }.message
    end
  end

  def test_rejects_ignored_source_collected_by_the_package_glob
    with_package do |_release, artifact|
      commit_package_source
      FileUtils.mkdir_p("lib")
      File.write("lib/local_only.rb", "puts :local_only\n")
      File.write(".git/info/exclude", "lib/local_only.rb\n", mode: "a")
      rebuild_package
      assert_empty git("status", "--porcelain")

      error = publishing_source_error(artifact)
      assert_match "not in release commit: lib/local_only.rb", error.message
      # 提交前的 dry-run 仍可检验候选包，但不能以此证明发布来源。
      capture_io { Release.new(artifact:, dry_run: true).run }
    end
  end

  def test_rejects_source_changes_hidden_from_git_status
    with_package do |_release, artifact|
      commit_package_source
      git("update-index", "--assume-unchanged", "payload.rb")
      File.binwrite("payload.rb", "puts :changed\n\n")
      rebuild_package
      assert_empty git("status", "--porcelain")
      assert_match "differs from release commit: payload.rb", publishing_source_error(artifact).message
    end
  end

  def test_rejects_executable_mode_changes_hidden_from_git_status
    with_package do |_release, artifact|
      commit_package_source
      git("config", "core.filemode", "false")
      File.chmod(0o755, "payload.rb")
      rebuild_package
      assert_empty git("status", "--porcelain")
      assert_match "permissions differ from release commit: payload.rb", publishing_source_error(artifact).message
    end
  end

  def test_rejects_altered_homepage_metadata
    with_package do |release, _artifact|
      spec = Gem::Specification.load(File.expand_path("expect-pty.gemspec")).dup
      spec.homepage = "https://example.invalid/altered"
      capture_io { Gem::Package.build(spec) }
      assert_match "metadata", assert_raises(RuntimeError) { release.send(:verify_package) }.message
    end
  end

  def test_rejects_different_installation_metadata_even_with_identical_source_files
    with_package do |release, _artifact|
      expected = Gem::Specification.load(File.expand_path("expect-pty.gemspec")).dup
      expected.add_runtime_dependency "unexpected-dependency", "= 1.0.0"
      Gem::Specification.stub(:load, expected) do
        assert_match "metadata", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      end
      expected = Gem::Specification.load(File.expand_path("expect-pty.gemspec")).dup
      expected.extensions = ["payload.rb"]
      Gem::Specification.stub(:load, expected) do
        assert_match "metadata", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      end
    end
  end

  def test_registry_errors_are_not_treated_as_an_unpublished_version
    release = Release.new
    response = Struct.new(:code, :body).new("503", "unavailable")
    release.stub(:get, response) { assert_raises(RuntimeError) { release.send(:registry_version) } }
  end

  def test_rejects_overwriting_a_published_version_or_reusing_a_yanked_version
    release = Release.new
    release.instance_variable_set(:@sha256, "expected")
    [{ "sha" => "different", "yanked" => false }, { "sha" => "expected", "yanked" => true }].each do |version|
      assert_raises(RuntimeError) { release.send(:verify_registry_checksum, version) }
    end
  end

  def test_existing_registry_version_is_downloaded_and_verified_without_pushing_again
    release = Release.new
    bytes = "published gem"
    checksum = Digest::SHA256.hexdigest(bytes)
    release.instance_variable_set(:@sha256, checksum)
    response = Struct.new(:code, :body).new("200", bytes)
    release.stub(:registry_version, { "sha" => checksum, "yanked" => false }) do
      release.stub(:system, ->(*) { flunk "repushed an existing gem" }) do
        release.stub(:get, response) { capture_io { release.send(:publish_rubygems) } }
        response.body = "different bytes"
        release.stub(:get, response) { assert_raises(RuntimeError) { release.send(:publish_rubygems) } }
      end
    end
  end

  def test_remote_tag_must_point_to_the_verified_commit
    release = Release.new
    release.instance_variable_set(:@commit, "verified")
    capture = ->(*arguments) { arguments.include?("rev-parse") ? "verified" : "" }
    github = lambda do |path, **|
      { "status" => (path.end_with?("...main") ? "ahead" : "behind") }
    end
    release.stub(:capture, capture) do
      release.stub(:github, github) do
        assert_match "another commit", assert_raises(RuntimeError) { release.send(:verify_remote_source) }.message
      end
    end
  end

  def test_package_validation_uses_archive_modes_regardless_of_umask
    with_package do |release, artifact|
      File.chmod(0o755, "payload.rb")
      capture_io { Gem::Package.build(Gem::Specification.load(File.expand_path("expect-pty.gemspec"))) }
      previous_umask = File.umask(0o077)
      begin
        release.send(:verify_package)
        assert File.file?(artifact)
        File.chmod(0o644, "payload.rb")
        assert_match "permissions differ", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      ensure
        File.umask(previous_umask)
      end
    end
  end

  def test_incomplete_github_asset_has_an_explicit_recovery_message
    release = Release.new
    release.instance_variable_set(:@checksum_file, "SHA256SUMS")
    remote = { "assets" => [{ "name" => "SHA256SUMS", "state" => "starter" }] }
    release.stub(:github_release, remote) do
      error = assert_raises(RuntimeError) { release.send(:publish_github) }
      assert_match "Incomplete GitHub asset: SHA256SUMS", error.message
      assert_match "stop any active upload", error.message
    end
  end

  private

  # CLI 按自身路径定位项目根目录；复制入口和版本文件，避免误读开发仓库的 CHANGELOG。
  def locale_script
    FileUtils.mkdir_p(["script", "lib/expect"])
    FileUtils.cp(File.expand_path("../script/release.rb", __dir__), "script/release.rb")
    FileUtils.cp(File.expand_path("../lib/expect/version.rb", __dir__), "lib/expect/version.rb")
    File.expand_path("script/release.rb")
  end

  def release_environment
    names = ENV.keys.grep(/\ABUNDLE/) + %w[RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS]
    names.to_h { |name| [name, nil] }
  end

  def git(*)
    output, error, status = Open3.capture3("git", *)
    assert status.success?, error
    output
  end

  def commit_package_source
    git("init", "--quiet")
    git("config", "core.hooksPath", File::NULL)
    File.write(".git/info/exclude", "*.gem\ntmp/\n")
    git("add", "--", "payload.rb", "CHANGELOG.md", "expect-pty.gemspec")
    git("-c", "user.name=Release Test", "-c", "user.email=release-test@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Release fixture")
  end

  def rebuild_package
    # Gem::Specification.load 会缓存已加载的 gemspec；重新执行才能看到新的 glob 文件。
    Gem::Specification.reset
    spec = Gem::Specification.load(File.expand_path("expect-pty.gemspec"))
    capture_io { Gem::Package.build(spec) }
  end

  def publishing_source_error(artifact)
    release = Release.new(artifact:, rubygems_only: true)
    release.stub(:get, ->(*) { flunk "uncommitted package content reached RubyGems" }) do
      error = nil
      capture_io { error = assert_raises(RuntimeError) { release.run } }
      error
    end
  end

  # 发布测试显式控制凭据环境，避免本机登录状态或 CI 标记影响用例结果。
  def with_environment(values)
    previous = values.to_h { |name, _value| [name, ENV.fetch(name, nil)] }
    begin
      values.each { |name, value| ENV[name] = value }
      yield
    ensure
      previous.each { |name, value| ENV[name] = value }
    end
  end

  def with_package
    Dir.mktmpdir("expect-release-test-") do |directory|
      Dir.chdir(directory) do
        File.write("payload.rb", "puts :original\n")
        File.write("CHANGELOG.md", "## #{Expect::VERSION}\n\n- Release fixture.\n")
        File.write("expect-pty.gemspec", <<~RUBY)
          Gem::Specification.new do |spec|
            spec.name = "expect-pty"
            spec.version = "#{Expect::VERSION}"
            spec.summary = "Release test fixture"
            spec.authors = ["Test"]
            spec.license = "MIT"
            spec.homepage = "https://github.com/gatework/expect-ruby"
            spec.files = ["payload.rb", "CHANGELOG.md", "expect-pty.gemspec"] + Dir["lib/**/*.rb"]
          end
        RUBY
        artifact = nil
        capture_io { artifact = Gem::Package.build(Gem::Specification.load(File.expand_path("expect-pty.gemspec"))) }
        yield Release.new(artifact:, dry_run: true), artifact
      end
    end
  end
end
