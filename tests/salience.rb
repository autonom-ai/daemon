require 'minitest/autorun'

require_relative 'support'
require_relative '../source/salience'

class SalienceTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    write_room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_unread_lines_reports_undrained_signals()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))
    Bus.dm(@marlow, 'dm text', from: @wren)
    Bus.post(room('general'), 'room text', from: @wren)

    lines = Salience.unread_lines(Bus.unread(@marlow))

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #room:general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert_equal 1, Bus.pings_by_profile(@marlow).unread(@marlow).length
  end

  def test_stop_text_is_strictly_task_based()
    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'continue the current user task'
    assert_includes text, 'Do not invent side quests'
    assert_includes text, 'choose a relevant room'
    refute_includes text, 'activity drive'
  end

  def test_briefing_carries_identity_team_and_room_without_memory()
    File.write(
      File.join(@marlow.directory, 'identity.md'),
      "---\ndisplayName: Marlow\n---\n\nI read the kill columns.\n"
    )
    Bus.post(room('general'), 'hello team', from: @wren)

    text = Salience.briefing(@marlow)

    assert_includes text, 'You are Marlow (marlow)'
    assert_includes text, 'I read the kill columns.'
    assert_includes text, 'Rooms: #general'
    assert_includes text, 'Teammates: wren'
    assert_includes text, 'hello team'
    refute_includes text, 'Your memory'
  end

  def test_briefing_asks_an_unclaimed_tab_to_claim_an_agent_name()
    text = Salience.briefing(nil)

    assert_includes text, 'Claim your name with set_profile'
    assert_includes text, 'human profile is reserved'
  end

  def test_ping_lines_format_unread_pings()
    Bus.ping(@marlow, '@marlow check the pricer', from: @wren, room: room('general'))

    text = Salience.ping_lines(Bus.pings_by_profile(@marlow).unread(@marlow)).join("\n")

    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'wren in #room:general'
    assert_includes text, '@marlow check the pricer'
  end
end
