# frozen_string_literal: true

# Optional differential check. The ordinary test suite has no Perl dependency.
require "json"
require "open3"
require "rbconfig"
require_relative "../lib/expect"

upstream = ARGV.fetch(0) { abort "usage: ruby test/compare_upstream.rb /path/to/expect.pm" }
perl = <<~'PERL'
  use strict;
  use warnings;
  use Expect;
  use JSON::PP;
  my %results;
  sub fresh {
    my ($buffer) = @_;
    my $e = Expect->new;
    $e->log_stdout(0);
    $e->set_accum($buffer);
    return $e;
  }
  sub snapshot {
    my ($e) = @_;
    my $captures = $e->exp_matchlist;
    return { number => $e->match_number, before => $e->before,
             match => $e->match, after => $e->after, captures => $captures || [],
             accum => $e->get_accum };
  }
  my $e = fresh('before a.c after');
  $e->expect(0, 'absent', 'a.c');
  $results{literal} = snapshot($e);
  $e = fresh('prefix value=42 tail');
  $e->expect(0, ['value=(\d+)']);
  $results{regexp_array} = snapshot($e);
  $e = fresh("first\nsecond\nthird");
  $e->expect(0, '-re', '^second$');
  $results{multiline} = snapshot($e);
  $e = fresh('second first');
  $e->expect(0, 'first', 'second');
  $results{priority} = snapshot($e);
  $e = fresh('before token tail');
  $e->notransfer(1);
  $e->expect(0, 'token');
  $results{notransfer} = snapshot($e);
  $e = fresh('discard tail');
  $e->max_accum(4);
  $e->expect(0, 'tail');
  $results{max_accum} = snapshot($e);
  $e = fresh('keep this');
  $e->expect(0, 'missing');
  $results{timeout} = { error => $e->exp_error, before => $e->before, accum => $e->get_accum };
  $e = fresh('A B C End');
  my @states;
  $e->expect(1, ['[ABC]', sub { push @states, $_[0]->match; exp_continue }], 'End');
  $results{continue} = { states => \@states, final => $e->match, number => $e->match_number };
  $e = fresh('');
  $e->raw_pty(1);
  $e->spawn($^X, '-e', '$|=1; while (<STDIN>) { chomp; print scalar(reverse($_)), "\n" }');
  $e->send("crate\n");
  $e->expect(3, 'etarc');
  $results{pty_dialogue} = { before => $e->before, match => $e->match, number => $e->match_number };
  $e->hard_close;
  pipe(my $reader, my $writer) or die $!;
  $writer->autoflush(1);
  my $input = Expect->exp_init($reader);
  my $idle = fresh('');
  print $writer 'beforeSTOP42;after';
  $results{readiness} = [Expect::test_handles(1, $idle, $input)];
  my @escapes;
  $input->set_seq('STOP\d+;', sub { push @escapes, 'stopped'; return 0; });
  Expect::interconnect($input);
  $results{regexp_escape} = \@escapes;
  close $writer;
  print JSON::PP->new->canonical->encode(\%results);
PERL

output, errors, status = Open3.capture3("perl", "-I#{File.join(upstream, "lib")}", "-e", perl)
abort "Perl fixture failed: #{errors}" unless status.success?
expected = JSON.parse(output)
actual = {}
sessions = []
fresh = lambda do |buffer|
  session = Expect.new(log_stdout: false)
  sessions << session
  session.buffer = buffer
  session
end
snapshot = lambda do |s|
  { "number" => s.match_number, "before" => s.before, "match" => s.match,
    "after" => s.after, "captures" => s.captures, "accum" => s.buffer }
end

begin
  s = fresh.call("before a.c after")
  s.expect("absent", "a.c", timeout: 0)
  actual["literal"] = snapshot.call(s)
  s = fresh.call("prefix value=42 tail")
  s.expect(/value=(\d+)/, timeout: 0)
  actual["regexp_array"] = snapshot.call(s)
  s = fresh.call("first\nsecond\nthird")
  s.expect(/^second$/, timeout: 0)
  actual["multiline"] = snapshot.call(s)
  s = fresh.call("second first")
  s.expect("first", "second", timeout: 0)
  actual["priority"] = snapshot.call(s)
  s = fresh.call("before token tail")
  s.preserve_buffer = true
  s.expect("token", timeout: 0)
  actual["notransfer"] = snapshot.call(s)
  s = fresh.call("discard tail")
  s.buffer_limit = 4
  s.expect("tail", timeout: 0)
  actual["max_accum"] = snapshot.call(s)
  s = fresh.call("keep this")
  s.expect("missing", timeout: 0)
  actual["timeout"] =
    { "error" => (s.error == :timeout ? "1:TIMEOUT" : s.error), "before" => s.before, "accum" => s.buffer }
  s = fresh.call("A B C End")
  states = []
  s.expect(timeout: 1) do
    on(/[ABC]/) do |object|
      states << object.match
      Expect.continue
    end
    on("End")
  end
  actual["continue"] = { "states" => states, "final" => s.match, "number" => s.match_number }
  s = fresh.call("")
  s.raw_pty = true
  s.spawn(RbConfig.ruby, "--disable-gems", "-e",
          "STDOUT.sync = true; while line = STDIN.gets; puts line.chomp.reverse; end")
  s.write("crate\n")
  s.expect("etarc", timeout: 3)
  actual["pty_dialogue"] = { "before" => s.before, "match" => s.match, "number" => s.match_number }
  reader, writer = IO.pipe
  input = Expect.open(reader, own: true)
  sessions << input
  idle = fresh.call("")
  writer.write("beforeSTOP42;after")
  actual["readiness"] = Expect.readable_sessions(idle, input, timeout: 1).map { |session| [idle, input].index(session) }
  escapes = []
  input.on_sequence(/STOP\d+;/) do
    escapes << "stopped"
    false
  end
  Expect.interconnect(input, timeout: 1)
  actual["regexp_escape"] = escapes
  writer.close

  failures = expected.keys.reject { |key| actual.fetch(key) == expected.fetch(key) }
  failures.each { |key| warn "#{key}: Perl=#{expected[key].inspect} Ruby=#{actual[key].inspect}" }
  abort "#{failures.length} upstream comparisons failed" unless failures.empty?
  puts "#{expected.length} upstream comparisons passed (Expect.pm #{File.basename(upstream)})"
ensure
  sessions.reverse_each { |session| session.hard_close(timeout: 0.03) }
end
