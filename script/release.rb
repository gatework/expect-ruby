#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rubygems/package"
require "tmpdir"
require_relative "../lib/expect/version"

# 本地使用 gem / gh 已有的登录状态；CI 传入测试过的包，发布阶段不重新构建。
class Release
  REPOSITORY = "gatework/expect-ruby"
  GEM_HOST = "https://rubygems.org"

  def initialize(artifact: nil, dry_run: false, rubygems_only: false)
    @version = Expect::VERSION
    @tag = "v#{@version}"
    @artifact = File.expand_path(artifact || "tmp/ci/expect-pty-#{@version}.gem")
    @dry_run = dry_run
    @rubygems_only = rubygems_only
    @build = artifact.nil?
  end

  def run
    notes = self.class.read_notes("CHANGELOG.md", @version)
    unless @dry_run || capture("git", "status", "--porcelain").empty?
      raise "Commit all source changes before publishing"
    end

    @commit = capture("git", "rev-parse", "HEAD") unless @dry_run

    command("bash", "script/ci") if @build
    # 独占目录中的副本贯穿校验和上传，其他构建不会改变本次发布的字节。
    directory = File.join("tmp", "release", @version)
    FileUtils.mkdir_p(directory)
    directory = Dir.mktmpdir("candidate-", directory)
    candidate = File.join(directory, "expect-pty-#{@version}.gem")
    FileUtils.cp(@artifact, candidate)
    @artifact = File.expand_path(candidate)
    verify_package
    @sha256 = Digest::SHA256.file(@artifact).hexdigest
    @checksum_file = File.join(directory, "SHA256SUMS")
    @notes_file = File.join(directory, "release-notes.md")
    File.write(@checksum_file, "#{@sha256}  #{File.basename(@artifact)}\n")
    File.write(@notes_file, "#{notes}\n", encoding: "UTF-8")
    puts "Verified #{@tag}: #{@sha256}\nArtifact: #{@artifact}"
    return puts "Dry run complete: #{@artifact}" if @dry_run

    if @rubygems_only
      verify_local_source
    else
      verify_remote_source
      verify_registry_checksum(registry_version)
      publish_github
    end
    publish_rubygems
  end

  # 有未归档的变更时拒绝发布，避免把新接口放进旧版本或遗漏发布说明。
  def self.read_notes(path, version)
    changelog = File.read(path, encoding: "UTF-8")
    raise "Invalid UTF-8 in #{path}" unless changelog.valid_encoding?

    release_notes(changelog, version)
  end

  # 纯章节解析与文件编码边界分离，本地入口和工作流共用 read_notes。
  def self.release_notes(changelog, version)
    raise "Use a stable X.Y.Z version" unless /\A\d+\.\d+\.\d+\z/.match?(version)

    sections = changelog.split(/^## /).drop(1).map do |section|
      heading, body = section.split("\n", 2)
      [heading.strip, body]
    end
    unreleased = sections.find { |heading, _body| heading == "Unreleased" }
    if unreleased && !unreleased[1].to_s.strip.empty?
      raise "Move Unreleased changes into the versioned changelog before releasing"
    end

    section = sections.find do |heading, _body|
      /\A#{Regexp.escape(version)}(?: - \d{4}-\d{2}-\d{2})?\z/.match?(heading)
    end
    raise "Missing release notes for #{version}" unless section && !section[1].to_s.strip.empty?

    section[1].strip
  end

  # README 的安装示例必须使用当前版本；历史发布说明不参与此校验。
  def self.validate_readme!(text, version)
    references = text.scan(/expect-pty-(\d+\.\d+\.\d+)\.gem/).flatten
    references.concat(text.scan(/gem "expect-pty", "~> (\d+\.\d+\.\d+)"/).flatten)
    stale = references.reject { |reference| reference == version }.uniq
    raise "README version references differ from #{version}: #{stale.join(", ")}" unless stale.empty?
  end

  private

  def capture(*)
    capture_bytes(*).strip
  end

  # Git blob 是任意字节，不能沿用命令文本的 strip，尾部换行和 NUL 也属于发布内容。
  def capture_bytes(*arguments)
    output, error, status = Open3.capture3(*arguments, binmode: true)
    raise "#{arguments.first} failed: #{error.strip}" unless status.success?

    output
  end

  def command(*arguments)
    raise "#{arguments.first} failed" unless system(*arguments)
  end

  def github(path, missing: false)
    output, error, status = Open3.capture3("gh", "api", "repos/#{REPOSITORY}/#{path}")
    return nil if missing && !status.success? && error.include?("HTTP 404")
    raise "GitHub API failed: #{error.strip}" unless status.success?

    JSON.parse(output)
  end

  def verify_local_source
    return if capture("git", "rev-parse", "HEAD") == @commit && capture("git", "status", "--porcelain").empty?

    raise "Source changed during verification; commit the changes and start again"
  end

  def verify_remote_source
    verify_local_source

    comparison = github("compare/#{@commit}...main")
    raise "Push this commit to #{REPOSITORY}/main first" unless %w[ahead identical].include?(comparison.fetch("status"))

    return unless github("git/ref/tags/#{@tag}", missing: true)
    return if github("compare/#{@tag}...#{@commit}").fetch("status") == "identical"

    raise "Remote tag #{@tag} points to another commit"
  end

  # 检查包内每个文件，防止拿旧包或其他提交的产物发布到当前标签。
  def verify_package
    package = Gem::Package.new(@artifact)
    expected = Gem::Specification.load(File.expand_path("expect-pty.gemspec"))
    fields = %i[name version platform summary description authors licenses homepage required_ruby_version
                required_rubygems_version require_paths metadata dependencies extensions executables bindir
                post_install_message]
    unless fields.all? { |field| package.spec.public_send(field) == expected.public_send(field) }
      raise "Artifact metadata does not match the gemspec"
    end
    raise "Artifact file list differs from the source" unless package.contents.sort == expected.files.sort

    self.class.validate_readme!(File.read("README.md"), @version) if expected.files.include?("README.md")

    committed = committed_files if @commit
    # 直接检查归档中的权限，避免解包时本机 umask 改写执行位。
    File.open(@artifact, "rb") do |io|
      Gem::Package::TarReader.new(io) do |archive|
        data = archive.find { |entry| entry.full_name == "data.tar.gz" }
        package.open_tar_gz(data) do |tar|
          tar.each do |entry|
            file = entry.full_name
            bytes = entry.read
            raise "Artifact differs from source: #{file}" unless entry.file? && bytes == File.binread(file)

            verify_committed_file(file, bytes, entry.header.mode, committed) if committed
            next if entry.header.mode & 0o111 == File.stat(file).mode & 0o111

            raise "Artifact executable permissions differ: #{file}"
          end
        end
      end
    end
  end

  # 工作区干净不代表所有打包文件都来自提交：ignore、assume-unchanged 和 filemode 均可隐藏差异。
  # 只在正式发布时核对提交树；dry-run 仍允许检验尚未提交的开发源码。
  def committed_files
    capture_bytes("git", "ls-tree", "-rz", "--full-tree", @commit).split("\0").to_h do |record|
      metadata, file = record.split("\t", 2)
      mode, type, object = metadata.split
      [file, [mode.to_i(8), type, object]]
    end
  end

  def verify_committed_file(file, bytes, mode, committed)
    committed_mode, type, object = committed[file.b]
    unless type == "blob" && committed_mode & 0o170000 == 0o100000
      raise "Artifact file is not in release commit: #{file}"
    end
    unless bytes == capture_bytes("git", "cat-file", "blob", object)
      raise "Artifact differs from release commit: #{file}"
    end
    return if mode & 0o111 == committed_mode & 0o111

    raise "Artifact executable permissions differ from release commit: #{file}"
  end

  def get(path)
    require "net/http"

    uri = URI("#{GEM_HOST}#{path}")
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
  end

  def registry_version
    response = get("/api/v2/rubygems/expect-pty/versions/#{@version}.json")
    return nil if response.code == "404"
    raise "RubyGems lookup failed: HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  end

  def verify_registry_checksum(version)
    return unless version
    return if !version.fetch("yanked") && version.fetch("sha") == @sha256

    raise "RubyGems already has different or yanked bytes for #{@version}; use the original artifact or a new version"
  end

  # gh 同时查找已发布版本和遗留草稿，REST 按标签查询只能找到已发布版本。
  def github_release
    output, error, status = Open3.capture3("gh", "release", "view", @tag, "--repo", REPOSITORY,
                                           "--json", "isDraft,assets")
    return nil if !status.success? && error.strip == "release not found"
    raise "GitHub Release lookup failed: #{error.strip}" unless status.success?

    JSON.parse(output)
  end

  # 先补齐 GitHub Release；RubyGems 认证失败时，已上传的原包仍可用于重试。
  def publish_github
    release = github_release
    assets = [@artifact, @checksum_file]
    if release
      existing, missing = assets.partition do |asset|
        entry = release.fetch("assets").find { |item| item.fetch("name") == File.basename(asset) }
        if entry && entry.fetch("state") != "uploaded"
          raise "Incomplete GitHub asset: #{entry.fetch("name")}; stop any active upload, remove the incomplete " \
                "asset in GitHub Release, then retry with the same artifact"
        end
        entry
      end
      verify_github_assets(existing)
      missing.each { |asset| command("gh", "release", "upload", @tag, asset, "--repo", REPOSITORY) }
      verify_github_assets(missing)
      if release.fetch("isDraft")
        command("gh", "release", "edit", @tag, "--repo", REPOSITORY, "--target", @commit, "--draft=false")
      end
    else
      command("gh", "release", "create", @tag, *assets, "--repo", REPOSITORY, "--target", @commit,
              "--title", @tag, "--notes-file", @notes_file)
      verify_github_assets(assets)
    end
    unless github("compare/#{@tag}...#{@commit}").fetch("status") == "identical"
      raise "Published tag points to another commit"
    end

    puts "GitHub Release: https://github.com/#{REPOSITORY}/releases/tag/#{@tag}"
  end

  def verify_github_assets(assets)
    # 新上传的附件也读回核验，工作流成功不代替远端产物校验。
    Dir.mktmpdir("expect-release-readback-") do |directory|
      assets.each do |asset|
        name = File.basename(asset)
        command("gh", "release", "download", @tag, "--repo", REPOSITORY, "--pattern", name, "--dir", directory)
        unless Digest::SHA256.file(File.join(directory, name)).hexdigest == Digest::SHA256.file(asset).hexdigest
          raise "GitHub Release asset verification failed: #{name}"
        end
      end
    end
  end

  def publish_rubygems
    version = registry_version
    verify_registry_checksum(version)
    unless version
      if ENV["GITHUB_ACTIONS"] == "true" && ENV.fetch("GEM_HOST_API_KEY", "").empty?
        raise "Configure RubyGems Trusted Publishing for release.yml, or publish locally with the existing gem login"
      end

      pushed = system("gem", "push", @artifact, "--host", GEM_HOST)
      # 推送返回失败也先读取远端，避免连接中断后盲目重复上传。
      version = registry_version
      verify_registry_checksum(version)
      raise "gem push failed; check RubyGems authentication and retry with the same artifact" unless pushed || version
    end

    6.times do |attempt|
      response = get("/downloads/expect-pty-#{@version}.gem")
      if response.code == "200"
        raise "Downloaded RubyGems artifact checksum differs" unless Digest::SHA256.hexdigest(response.body) == @sha256

        return puts "RubyGems: #{GEM_HOST}/gems/expect-pty/versions/#{@version} (SHA256 verified)"
      end
      raise "RubyGems download failed: HTTP #{response.code}" unless response.code == "404"

      sleep 2 unless attempt == 5
    end
    raise "RubyGems download is not available yet; retry with the same artifact"
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |arguments|
    arguments.banner = "Usage: ruby script/release.rb [--rubygems-only] [--dry-run] [--artifact PATH]"
    arguments.on("--rubygems-only", "Publish only to RubyGems using the existing gem login; no GitHub access") do
      options[:rubygems_only] = true
    end
    arguments.on("--artifact PATH", "Publish an already verified gem without rebuilding") do |path|
      options[:artifact] = File.expand_path(path)
    end
    arguments.on("--dry-run", "Build and verify locally without publishing") { options[:dry_run] = true }
  end
  begin
    parser.parse!
    raise OptionParser::InvalidArgument, ARGV.join(" ") unless ARGV.empty?

    Dir.chdir(File.expand_path("..", __dir__)) { Release.new(**options).run }
  rescue StandardError => error
    warn "Release aborted: #{error.message}"
    exit 1
  end
end
