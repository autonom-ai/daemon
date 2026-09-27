require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/agent/profile'
require_relative '../source/agent/salience'

class SalienceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_unread_lines_reports_undrained_signals
    Agent::Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    Agent::Profile.dm('marlow', 'dm text', from: 'wren', root: @root)
    Room.post('general', 'room text', from: 'wren', root: @root)

    unread = Agent::Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)
    lines = Agent::Salience.unread_lines(unread)

    assert lines.any? { |line| line.include?('Unread pings (1)') }
    assert lines.any? { |line| line.include?('Unread direct messages (1)') }
    assert lines.any? { |line| line.include?('New #general traffic (1)') }
    assert lines.any? { |line| line.include?('ping text') }
    assert lines.any? { |line| line.include?('dm text') }
    assert lines.any? { |line| line.include?('room text') }
    assert_equal 1, Agent::Profile.unread_pings('marlow', root: @root).length
  end

  def test_stop_text_is_one_complete_message
    Agent::Profile.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    unread = Agent::Profile.get_unread('marlow', rooms: ['general'], rooms_root: @root, root: @root)

    text = Agent::Salience.stop_text(unread)

    assert_includes text, 'Do not end the turn yet'
    assert_includes text, 'Unread pings (1)'
    assert_includes text, 'call wait_for_message on the room'
    refute_includes text, 'cadence'
  end
end
