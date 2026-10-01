# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/support/ssh"

class SSHExampleTest < ExpectTest
  def test_loopback_uses_isolated_known_hosts_and_explicit_arguments
    options = SSHExample.options("USER" => "alice", "SSH_PORT" => "2222")
    arguments = SSHExample.arguments(options, directory: "/tmp/private", prompt: "A '$ > ")

    assert_equal({ host: "127.0.0.1", user: "alice", port: 2222, known_hosts: nil }, options)
    assert_includes arguments, "StrictHostKeyChecking=accept-new"
    assert_includes arguments, 'UserKnownHostsFile="/tmp/private/known_hosts"'
    assert_equal %w[-l alice 127.0.0.1], arguments[-4, 3]
    assert_equal ["env", "ENV=", "PS1=A '$ > ", "/bin/sh", "-i"], Shellwords.split(arguments.last)
  end

  def test_remote_host_requires_a_trusted_hosts_file
    assert_raises(ArgumentError) { SSHExample.options("SSH_HOST" => "host.example", "USER" => "alice") }
    options = SSHExample.options("SSH_HOST" => "host.example", "USER" => "alice", "SSH_KNOWN_HOSTS" => "/trusted")
    arguments = SSHExample.arguments(options, directory: "/tmp/private", prompt: "> ")
    assert_includes arguments, "StrictHostKeyChecking=yes"
    assert_includes arguments, 'UserKnownHostsFile="/trusted"'
  end

  def test_known_hosts_is_one_quoted_filename_with_spaces_quotes_and_backslashes
    ["/tmp/known hosts", '/tmp/known"hosts', "/tmp/known'hosts", '/tmp/known\\hosts', "/tmp/known#hosts"].each do |path|
      options = SSHExample.options("USER" => "alice", "SSH_KNOWN_HOSTS" => path)
      arguments = SSHExample.arguments(options, directory: "/tmp/private", prompt: "> ")
      setting = arguments.find { |argument| argument.start_with?("UserKnownHostsFile=") }
      value = setting.delete_prefix("UserKnownHostsFile=")

      assert value.start_with?('"') && value.end_with?('"')
      assert_equal [path], Shellwords.split(value)
    end
    arguments = SSHExample.arguments(SSHExample.options("USER" => "alice"), directory: "/tmp/private dir", prompt: "> ")
    assert_includes arguments, 'UserKnownHostsFile="/tmp/private dir/known_hosts"'
  end

  def test_malformed_environment_values_are_rejected_before_connecting
    { "SSH_HOST" => ["", "-option", "two hosts", "host\0"], "SSH_USER" => ["", "-user", "two users"],
      "SSH_PORT" => %w[0 65536 22x], "SSH_KNOWN_HOSTS" => [""] }.each do |key, values|
      values.each { |value| assert_raises(ArgumentError) { SSHExample.options({ "USER" => "alice", key => value }) } }
    end
  end

  def test_password_is_removed_from_environment_and_copied_without_printing
    original = "top secret"
    environment = { "EXPECT_PASSWORD" => original }
    output = StringIO.new
    password = SSHExample.read_password(environment:, input: StringIO.new, output:)

    assert_equal original, password
    refute_same original, password
    refute environment.key?("EXPECT_PASSWORD")
    assert_empty output.string
  end

  def test_stdin_password_is_one_line_and_malformed_supplied_passwords_are_rejected
    output = StringIO.new
    assert_equal "password", SSHExample.read_password(environment: {}, input: StringIO.new("password\n"), output:)
    assert_equal "SSH password: \n", output.string
    ["", "one\ntwo", "one\rtwo", "one\0two"].each do |password|
      assert_raises(ArgumentError) do
        SSHExample.read_password(environment: { "EXPECT_PASSWORD" => password }, output:)
      end
    end
    assert_raises(ArgumentError) { SSHExample.read_password(environment: {}, input: StringIO.new, output:) }
  end
end
