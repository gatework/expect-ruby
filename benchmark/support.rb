# frozen_string_literal: true

require "json"
require "fileutils"
require "optparse"
require "open3"
require "digest"
require "socket"
require "timeout"

# 标准库基准入口；每个工作负载先验证结果，采样后再核对，计时不包含断言。
module ExpectBenchmark
  # 保存环境、输入规模、耗时、分配与 GC 样本，便于比较不同源码目录。
  class Runner
    attr_reader :smoke, :library

    def initialize(name)
      @library = File.expand_path("../lib", __dir__)
      @samples = 5
      @iterations = nil
      @smoke = false
      @output = "tmp/benchmark/#{name}.json"
      OptionParser.new do |options|
        options.banner = "Usage: ruby benchmark/#{name}.rb [options]"
        options.on("--smoke", "Small correctness workload") { @smoke = true }
        options.on("--library PATH", "Compare another checkout's lib directory") do |path|
          @library = File.expand_path(path)
        end
        options.on("--samples N", Integer) { |count| @samples = count }
        options.on("--iterations N", Integer) { |count| @iterations = count }
        options.on("--output PATH") { |path| @output = path }
        yield options if block_given?
      end.parse!
      unless @samples.positive? && (!@iterations || @iterations.positive?)
        raise ArgumentError, "counts must be positive"
      end

      require File.join(@library, "expect")
      @results = []
    end

    def measure(name, bytes:, inputs:, verify:, iterations: 100, &operation)
      iterations = @iterations || (smoke ? 1 : iterations)
      samples = smoke ? 1 : @samples
      verify.call(operation.call) # 同时预热；错误输出永远不能成为更快的样本。
      measurements = Array.new(samples) do
        GC.start
        resources_before = resources
        before = GC.stat
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        iterations.times { result = operation.call }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        after = GC.stat
        verify.call(result)
        {
          seconds: elapsed, allocated_objects: after[:total_allocated_objects] - before[:total_allocated_objects],
          gc_count: after[:count] - before[:count], processed_bytes: bytes * iterations,
          resources_before: resources_before, resources_after: resources
        }
      end
      @results << { name: name, inputs: inputs, iterations: iterations, samples: measurements }
      puts "#{name}: #{format("%.6f", measurements.map { |row| row[:seconds] }.sort[samples / 2])}s"
    end

    def finish
      root = File.dirname(library)
      repository = git_output(root, "rev-parse", "--show-toplevel")&.strip
      if repository && File.realpath(repository) == File.realpath(root)
        sha = git_output(root, "rev-parse", "HEAD")
        dirty = git_output(root, "status", "--porcelain", "--untracked-files=all")
      end
      digest = Digest::SHA256.new
      Dir[File.join(library, "**/*.rb")].each do |path|
        digest << path.delete_prefix(library) << File.binread(path)
      end
      report = {
        ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, revision: sha&.strip,
        fd_limit: Process.getrlimit(:NOFILE).first,
        dirty: dirty.nil? ? nil : !dirty.empty?, library_sha256: digest.hexdigest, smoke: smoke, results: @results
      }
      FileUtils.mkdir_p(File.dirname(@output))
      File.write(@output, "#{JSON.pretty_generate(report)}\n")
      puts "Saved #{@output}"
    end

    private

    # 资源采样在计时区间之外；RSS 是端点值，不冒充峰值。目录不可用时显式记录 nil。
    def resources
      directory = File.directory?("/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
      descriptors = Dir.children(directory).size if File.directory?(directory)
      rss = if File.file?("/proc/self/status")
              File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1]&.to_i
            else
              output, _, status = Open3.capture3("ps", "-o", "rss=", "-p", Process.pid.to_s)
              output.to_i if status.success?
            end
      { rss_bytes: rss && (rss * 1024), descriptors: descriptors }
    end

    # 安装包和源码归档可能没有 Git；未知状态记录为 nil，不误报为干净提交。
    def git_output(root, *)
      output, _, status = Open3.capture3("git", "-C", root, *)
      output if status.success?
    rescue Errno::ENOENT
      nil
    end
  end

  def self.check(condition, message = "incorrect benchmark output")
    raise message unless condition
  end
end
