require 'minitest/autorun'

require_relative '../support'
require_relative '../../source/salience/salience'

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
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, Bus.pings_by_profile(@marlow).unread(@marlow).length
  end

  def test_a_direct_message_outranks_room_traffic()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))
    Bus.dm(@marlow, 'dm text', from: @wren)
    Bus.post(room('general'), 'room text', from: @wren)

    focus = Salience.focus(Salience.impulses(Bus.unread(@marlow)))

    assert_equal 'Respond', focus.kind
    assert focus.required?
    assert_includes focus.context, 'ping text'
    assert_includes focus.context, 'dm text'
    assert_equal 'Action', focus.channel
  end

  def test_room_traffic_alone_is_a_coordinate_impulse()
    Bus.post(room('general'), 'anyone around?', from: @wren)

    focus = Salience.focus(Salience.impulses(Bus.unread(@marlow)))

    assert_equal 'Coordinate', focus.kind
    refute focus.required?
  end

  def test_stop_text_is_one_complete_message()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))

    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'Answer what is owed first'
  end

  def test_stop_text_hands_the_turn_back_as_free_time_when_nothing_is_owed()
    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Nothing is owed'
    assert_includes text, 'The turn is yours'
    refute_includes text, 'wait_for_message'
  end

  def test_a_starved_social_drive_is_a_report_impulse()
    8.times { Salience::Activity.record(@marlow, 'edit', { 'file_path' => 'source/x.rb' }) }

    impulses = Salience.activity_impulses(@marlow)

    assert_equal 1, impulses.length
    assert_equal 'Report', impulses.first.kind
    assert_equal 'activity', impulses.first.origin
    refute impulses.first.required?
    assert_includes impulses.first.context, 'source/x.rb'
  end

  def test_a_starved_work_drive_is_a_continue_impulse()
    5.times { Salience::Activity.record(@marlow, 'read', {}) }
    3.times { Salience::Activity.record(@marlow, 'mcp__autonom-coord-mcp__send_message', {}) }

    impulse = Salience.activity_impulses(@marlow).first

    assert_equal 'Continue', impulse.kind
  end

  def test_a_starved_explore_drive_is_an_explore_impulse()
    File.write(
      File.join(@marlow.directory, 'identity.md'),
      "---\ndisplayName: Marlow\n---\n\n## Interests\n\n- kill columns\n"
    )
    8.times { Salience::Activity.record(@marlow, 'edit', {}) }
    2.times { Salience::Activity.record(@marlow, 'mcp__autonom-coord-mcp__send_message', {}) }

    impulse = Salience.activity_impulses(@marlow).first

    assert_equal 'Explore', impulse.kind
    assert_includes impulse.context, 'kill columns'
  end

  def test_stop_text_surfaces_one_activity_impulse_when_nothing_is_owed()
    8.times { Salience::Activity.record(@marlow, 'edit', { 'file_path' => 'source/x.rb' }) }

    text = Salience.stop_text(@marlow)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'The turn is yours'
    assert_includes text, 'Tell the room what you are doing'
    assert_includes text, 'source/x.rb'
  end

  def test_unread_still_outranks_a_starved_drive()
    Bus.ping(@marlow, 'ping text', from: @wren, room: room('general'))
    8.times { Salience::Activity.record(@marlow, 'edit', {}) }

    text = Salience.stop_text(@marlow)

    assert_includes text, 'Unread pings (1)'
    refute_includes text, 'Tell the room what you are doing'
  end

  def test_briefing_carries_identity_memory_team_and_room()
    write_config('project' => 'jobs', 'memory' => true)
    File.write(File.join(@marlow.directory, 'identity.md'), "---\ndisplayName: Marlow\n---\n\nI read the kill columns.\n")
    FileUtils.mkdir_p(File.join(@marlow.directory, 'memories'))
    File.write(File.join(@marlow.directory, 'memories', 'memory.md'), "# marlow - memory\n\n## Now\n\nChecking the pricer.\n")
    Bus.post(room('general'), 'hello team', from: @wren)

    text = Salience.briefing(@marlow)

    assert_includes text, 'You are Marlow (marlow)'
    assert_includes text, 'I read the kill columns.'
    assert_includes text, 'Checking the pricer.'
    assert_includes text, 'Rooms: #room:general'
    assert_includes text, 'Teammates: wren'
    assert_includes text, 'hello team'
  end

  def test_briefing_asks_an_unclaimed_tab_to_claim_a_name()
    assert_includes Salience.briefing(nil), 'Claim your name with set_profile'
  end

  def test_ping_lines_format_unread_pings()
    Bus.ping(@marlow, '@marlow check the pricer', from: @wren, room: room('general'))

    text = Salience.ping_lines(Bus.pings_by_profile(@marlow).unread(@marlow)).join("\n")

    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'wren in #room:general'
    assert_includes text, '@marlow check the pricer'
  end
end
