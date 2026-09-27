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
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Inbox.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', project: @root)

    lines = Salience.unread_lines(unread)

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, Inbox.unread_pings('marlow', root: @root).length
  end

  def test_a_direct_message_outranks_room_traffic
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Inbox.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', project: @root)

    focus = Salience.focus(Salience.impulses(unread))

    assert_equal 'Respond', focus.kind
    assert focus.required?
    assert_includes focus.context, 'ping text'
    assert_includes focus.context, 'dm text'
    assert_equal 'Action', focus.channel
  end

  def test_room_traffic_alone_is_a_coordinate_impulse
    Room.post('general', 'anyone around?', from: 'wren', project: @root)

    focus = Salience.focus(Salience.impulses(unread))

    assert_equal 'Coordinate', focus.kind
    refute focus.required?
  end

  def test_stop_text_is_one_complete_message
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)

    text = Salience.stop_text('marlow', rooms: ['general'], project: @root, root: @root)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'call wait_for_message on the room'
  end

  def test_stop_text_is_nil_when_nothing_is_waiting
    assert_nil Salience.stop_text('marlow', rooms: ['general'], project: @root, root: @root)
  end

  private

  def unread
    Profile.get_unread('marlow', rooms: ['general'], project: @root, root: @root)
  end
end
