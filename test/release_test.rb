# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../script/release"

class ReleaseTest < Minitest::Test
  def test_extracts_only_the_selected_version
    changelog = "# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-09-12\n\n- New API.\n\n## 0.1.1\n\n- Old API.\n"
    assert_equal "- New API.", Release.release_notes(changelog, "0.2.0")
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
      directory = Dir.glob(File.join("pkg", "release", Expect::VERSION, "candidate-*")).fetch(0)
      checksum = File.read(File.join(directory, "SHA256SUMS"))
      assert_equal "#{Digest::SHA256.file(artifact).hexdigest}  #{File.basename(artifact)}\n", checksum
      assert_equal "- Release fixture.\n", File.read(File.join(directory, "release-notes.md"))
      File.write(artifact, "another build")
      assert_equal checksum.split.first, Digest::SHA256.file(File.join(directory, File.basename(artifact))).hexdigest
    end
  end

  def test_rejects_a_package_from_different_source
    with_package do |release, _artifact|
      File.write("payload.rb", "puts :changed\n")
      assert_match "Artifact differs from source", assert_raises(RuntimeError) { release.send(:verify_package) }.message
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
            spec.files = ["payload.rb", "CHANGELOG.md", "expect-pty.gemspec"]
          end
        RUBY
        artifact = nil
        capture_io { artifact = Gem::Package.build(Gem::Specification.load(File.expand_path("expect-pty.gemspec"))) }
        yield Release.new(artifact: artifact, dry_run: true), artifact
      end
    end
  end
end
