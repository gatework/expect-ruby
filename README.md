# expect-ruby

[![CI](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/gatework/expect-ruby/actions/workflows/ci.yml)

[English](README.md) · [简体中文](README.zh-CN.md)

A Ruby library for automating interactive programs through POSIX pseudo-terminals. Start a child process, wait for text or regular expressions, send input, and manage timeouts, callbacks, and cleanup with Ruby objects and blocks.

RubyGems package: **expect-pty**. Requires Ruby 3.4+ on Linux or macOS.

## Install

Add the gem to your Gemfile:

~~~ruby
gem "expect-pty", require: "expect/pty"
~~~

Then run `bundle install`, or install it directly with `gem install expect-pty`.

## Quick start

~~~ruby
require "expect/pty"

program = "STDOUT.sync = true; print 'ready>'; STDIN.gets; puts 'done'"
Expect.spawn("ruby", "-e", program) do |session|
  prompt = session.expect("ready>", timeout: 5)
  raise "child did not become ready" unless prompt.matched?

  session.puts("continue")
  result = session.expect("done", timeout: 5)
  puts result.match if result.matched?
end
~~~

The block closes the session and reaps its child process, including when the block raises. Use separate command arguments for untrusted input; a single command string follows Ruby shell semantics.

## Features

- Exact byte-string and Ruby Regexp matching, immutable results, callbacks, timeouts, and EOF handling.
- Explicit PTY sessions or borrowed IO sessions, with scoped cleanup and process status.
- Multi-session waits, IO forwarding, and interactive terminal handoff.
- Optional Logger diagnostics, receive transcripts, and streaming redaction.

## Documentation

- [API reference](docs/API.md)
- [Compatibility and behavior boundaries](docs/COMPATIBILITY.md)
- [Migration guide](docs/MIGRATION.md)
- [Performance notes](https://github.com/gatework/expect-ruby/blob/main/docs/PERFORMANCE.md)
- [Examples](https://github.com/gatework/expect-ruby/tree/main/examples)

In a repository checkout, run the test suite and package checks with `script/ci`. The suite uses local PTYs, pipes, and sockets; SSH credentials are not required.

Licensed under the MIT License. Contributions are welcome in English or Chinese; see [CONTRIBUTING.md](https://github.com/gatework/expect-ruby/blob/main/CONTRIBUTING.md).
