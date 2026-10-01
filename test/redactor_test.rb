# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../lib/expect/redactor"

class RedactorTest < Minitest::Test
  def test_standalone_require_does_not_load_pty_or_allocate_a_session
    program = <<~RUBY
      require "expect/redactor"
      abort "PTY loaded" if defined?(PTY)
      abort "unexpected result" unless Expect::Redactor.redact("secret!", ["secret"]) == "[FILTERED]!"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__),
                                     "-e", program)
    assert status.success?, output
  end

  def test_empty_patterns_pass_binary_input_without_buffering
    filter = Expect::Redactor.new([])
    assert_equal "\xff\0raw".b, filter.append("\xff\0raw".b)
    assert_empty filter.finish
    assert_equal "plain", Expect::Redactor.redact("plain", [])
  end

  def test_one_shot_redaction_does_not_treat_an_ordinary_suffix_as_a_secret_prefix
    assert_equal "pass", Expect::Redactor.redact("pass", ["password"])
    assert_equal "[REDACTED]!", Expect::Redactor.redact("password!", ["password"], replacement: "[REDACTED]")
  end

  def test_stream_finish_masks_partial_secrets_by_default
    filter = Expect::Redactor.new(["password"])
    assert_equal "prefix [FILTERED]", filter.append("prefix pass") + filter.finish
    assert_empty filter.finish
    assert_equal "[FILTERED]!", filter.append("password!") + filter.finish
  end

  def test_exact_finish_is_explicit_and_validated
    filter = Expect::Redactor.new(["password"])
    filter.append("pass")
    assert_raises(ArgumentError) { filter.finish(partial: nil) }
    assert_equal "pass", filter.finish(partial: false)
  end

  def test_custom_marker_and_overlapping_patterns_at_every_boundary
    patterns = ["alpha[REDACTED]omega", "[REDACTED]", "REDACTED", "[", "abc", "cde"]
    input = "alpha[REDACTED]omega | [REDACTED] | abcde!"
    expected = "[REDACTED] | [REDACTED] | [REDACTED]!"
    (0..input.bytesize).each do |split|
      filter = Expect::Redactor.new(patterns, replacement: "[REDACTED]")
      actual = filter.append(input.byteslice(0, split)) + filter.append(input.byteslice(split..)) + filter.finish
      assert_equal expected, actual, "split #{split}"
    end
    filter = Expect::Redactor.new(patterns, replacement: "[REDACTED]")
    actual = input.bytes.map { |byte| filter.append(byte.chr) }.join + filter.finish
    assert_equal expected, actual
    assert_equal expected, Expect::Redactor.redact(input, patterns, replacement: "[REDACTED]")
  end

  def test_patterns_and_replacement_are_copied
    secret = +"secret"
    patterns = [secret]
    replacement = +"hidden"
    filter = Expect::Redactor.new(patterns, replacement:)
    secret.replace("public")
    patterns.clear
    replacement.clear
    assert_equal "hidden!", filter.append("secret!") + filter.finish
  end

  def test_invalid_pattern_update_is_atomic_and_preserves_pending_data
    filter = Expect::Redactor.new(["secret"])
    filter.append("sec")
    [nil, "secret", [""], ["valid", 1]].each do |patterns|
      assert_raises(ArgumentError) { filter.patterns = patterns }
    end
    assert_equal "[FILTERED]!", filter.append("ret!") + filter.finish
  end

  def test_pattern_update_keeps_hidden_spans_and_matches_new_secret_across_chunks
    filter = Expect::Redactor.new(%w[abc long-pattern])
    filter.append("abcsec")
    filter.patterns = ["secret"]
    assert_equal "[FILTERED]!", filter.append("ret!") + filter.finish
    filter.patterns = []
    assert_equal "secret", filter.append("secret")
    assert_empty filter.finish
  end

  def test_invalid_input_and_replacement_do_not_mutate_stream
    [nil, "", 3].each do |replacement|
      assert_raises(ArgumentError) { Expect::Redactor.new([], replacement:) }
    end
    filter = Expect::Redactor.new(["secret"])
    filter.append("sec")
    assert_raises(ArgumentError) { filter.append(nil) }
    assert_equal "[FILTERED]!", filter.append("ret!") + filter.finish
  end

  def test_inspect_does_not_expose_registered_or_pending_bytes
    filter = Expect::Redactor.new(["private-pattern"])
    filter.append("raw-pending")
    assert_equal "#<Expect::Redactor>", filter.inspect
  end

  def test_seeded_binary_chunks_match_a_naive_union_of_full_and_partial_spans
    random = Random.new(5000)
    250.times do |index|
      alphabet = index.even? ? [97, 98] : [0, 97, 98, 99, 128, 255]
      input = Array.new(random.rand(0..120)) { alphabet.sample(random:) }.pack("C*")
      patterns = Array.new(random.rand(0..6)) do
        Array.new(random.rand(1..8)) { alphabet.sample(random:) }.pack("C*")
      end
      chunks = []
      offset = 0
      while offset < input.bytesize
        chunks << input.byteslice(offset, random.rand(1..15))
        offset += chunks.last.bytesize
      end
      [false, true].each do |partial|
        expected = reference_redact(input, patterns, partial:)
        [[input], input.bytes.map(&:chr), chunks].each_with_index do |partition, kind|
          filter = Expect::Redactor.new(patterns)
          actual = partition.map { |chunk| filter.append(chunk) }.join.b + filter.finish(partial:)
          assert_equal expected, actual, "seed=5000 case=#{index} partition=#{kind} partial=#{partial}"
          assert_empty filter.finish(partial:)
        end
      end
    end
  end

  def test_long_overlaps_merge_across_chunks_without_repeating_markers
    filter = Expect::Redactor.new(["a" * 1024, "a" * 32, "ab"])
    output = +""
    256.times { output << filter.append("a" * 17) }
    output << filter.append("b!") << filter.finish
    assert_equal "[FILTERED]!", output
  end

  def test_rule_removal_keeps_hidden_pending_bytes_and_partial_finish_is_separate
    filter = Expect::Redactor.new(%w[aaaa long-pattern])
    assert_empty filter.append("aaaaa")
    filter.patterns = ["abc"]
    assert_equal "[FILTERED]", filter.append("ab")
    assert_empty filter.finish # 新的疑似前缀紧邻已隐藏区域，不能重复输出替换标记。

    filter = Expect::Redactor.new(%w[aaaa long-pattern])
    assert_empty filter.append("aaaaa")
    filter.patterns = []
    assert_equal "[FILTERED]!", filter.append("!") + filter.finish
  end

  private

  # 独立参考模型：逐偏移比较完整秘密，再合并布尔掩码；不复用生产代码的扫描/输出实现。
  def reference_redact(input, patterns, partial:)
    hidden = Array.new(input.bytesize, false)
    patterns.each do |pattern|
      input.bytesize.times do |offset|
        next unless input.byteslice(offset, pattern.bytesize) == pattern

        pattern.bytesize.times { |length| hidden[offset + length] = true }
      end
      next unless partial

      (1...pattern.bytesize).each do |length|
        next unless input.end_with?(pattern.byteslice(0, length))

        ((input.bytesize - length)...input.bytesize).each { |offset| hidden[offset] = true }
      end
    end
    output = +"".b
    input.bytes.each_with_index do |byte, offset|
      if hidden[offset]
        output << "[FILTERED]" if offset.zero? || !hidden[offset - 1]
      else
        output << byte
      end
    end
    output
  end
end
