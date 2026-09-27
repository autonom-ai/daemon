require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/profile'
require_relative '../source/salience/salience'

class SalienceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_unread_lines_reports_undrained_signals
    Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Profile.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', root: @root)

    unread = Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)
    lines = Salience.unread_lines(unread)

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, Profile.unread_pings('marlow', root: @root).length
  end

  def test_a_direct_message_outranks_room_traffic
    Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Profile.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', root: @root)

    unread = Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)
    impulses = Salience.impulses(unread)
    focus = Salience.focus(impulses)

    assert_equal 'Respond', focus.kind
    assert focus.required?
    assert_includes focus.context, 'ping text'
    assert_includes focus.context, 'dm text'
    assert_equal 'Action', focus.channel
  end

  def test_room_traffic_alone_is_a_coordinate_impulse
    Room.post('general', 'anyone around?', from: 'wren', root: @root)

    unread = Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)
    focus = Salience.focus(Salience.impulses(unread))

    assert_equal 'Coordinate', focus.kind
    refute focus.required?
  end

  def test_no_unread_signals_means_no_focus
    unread = Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)

    assert_empty Salience.impulses(unread)
    assert_nil Salience.focus(Salience.impulses(unread))
  end

  def test_an_unknown_impulse_kind_is_refused
    assert_raises(ArgumentError) { Salience.impulse('Vibes', 'anything') }
  end

  def test_stop_text_is_one_complete_message
    Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    unread = Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)
    focus = Salience.focus(Salience.impulses(unread))

    text = Salience.stop_text(unread, focus: focus)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'call wait_for_message on the room'
  end
end
