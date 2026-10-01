# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/kibitz_probe"

class KibitzTest < ExpectTest
  def test_two_terminals_share_shell_echo_signals_and_logged_output
    Dir.mktmpdir { |directory| assert KibitzProbe.shared_shell(directory)[:passed] }
  end

  def test_noproc_split_custom_escape_does_not_leak_to_peer
    Dir.mktmpdir { |directory| assert KibitzProbe.direct(directory, ending: :host)[:passed] }
  end

  def test_guest_escape_ends_both_sides_and_restores_terminals
    Dir.mktmpdir { |directory| assert KibitzProbe.direct(directory, ending: :guest)[:passed] }
  end

  def test_noescape_forwards_control_character_as_data
    Dir.mktmpdir { |directory| assert KibitzProbe.noescape(directory)[:passed] }
  end

  def test_shared_process_failure_is_reported
    Dir.mktmpdir { |directory| assert KibitzProbe.process_failure(directory)[:passed] }
  end

  def test_relay_timeout_restores_terminals_and_closes_peer
    Dir.mktmpdir { |directory| assert KibitzProbe.relay_timeout(directory)[:passed] }
  end

  def test_missing_partner_times_out_and_removes_socket
    session = Expect::Session.new
    @sessions << session
    saved = InteractProbe.configuration(session)
    session.spawn(RbConfig.ruby, KibitzProbe::EXAMPLE, "--timeout", "0.2")
    result = session.expect(%r{--join (/tmp/expect-kibitz-[^\r\n ]+/peer\.sock)}, timeout: 3)
    assert result.matched?
    path = result.captures.first
    assert session.expect(:eof, timeout: 3).eof?
    assert_includes session.before, "timed out waiting for partner"
    assert_equal 1, session.wait(timeout: 1).exitstatus
    assert_equal saved, InteractProbe.configuration(session)
    refute File.exist?(File.dirname(path))
  end
end
