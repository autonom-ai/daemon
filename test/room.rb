require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/core/room'
require_relative '../source/core/agent/profile'

class RoomTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_messages_are_workspace_scoped
    Room.post('general', 'hello', from: 'marlow', root: @root)

    entries = Room.messages('general', root: @root)

    assert_equal ['hello'], entries.map { |entry| entry['text'] }
    assert_equal 'marlow', entries.first['from']
    assert File.file?(File.join(@root, '.devin', 'agent-coord', 'rooms', 'general.jsonl'))
    assert_empty Room.messages('other', root: @root)
  end

  def test_the_team_room_is_the_default_and_names_normalize
    write_coord(team_room: 'market')

    Room.post(nil, 'hi', from: 'wren', root: @root)
    Room.post('#Market', 'again', from: 'wren', root: @root)

    assert_equal %w[hi again], Room.messages(nil, root: @root).map { |entry| entry['text'] }
    assert_equal %w[hi again], Room.messages('market', root: @root).map { |entry| entry['text'] }
  end

  def test_invalid_room_names_are_refused
    assert_raises(Room::Error) { Room.messages('../secrets', root: @root) }
    assert_raises(Room::Error) { Room.post('a b', 'hi', from: 'wren', root: @root) }
  end

  def test_symlinked_room_files_are_refused
    rooms = File.join(@root, '.devin', 'agent-coord', 'rooms')
    FileUtils.mkdir_p(rooms)
    target = File.join(@root, 'elsewhere.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(rooms, 'general.jsonl'))

    assert_raises(Room::Error) { Room.messages('general', root: @root) }
    assert_raises(Room::Error) { Room.post('general', 'hi', from: 'wren', root: @root) }
  end

  def test_a_room_post_wakes_every_waiter_in_the_room
    woken = Queue.new
    waiters = %w[marlow wren].map do |agent|
      Thread.new do
        Room.wait('general', agent, timeout: 5)
        woken << agent
      end
    end
    sleep 0.2

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Room.post('general', 'hello', from: 'sable', root: @root)
    waiters.each { |waiter| waiter.join(3) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.5
    assert_equal %w[marlow wren], [woken.pop, woken.pop].sort
  end

  def test_a_ping_wakes_only_the_pinged_waiter
    woken = Queue.new
    Thread.new do
      Room.wait('general', 'wren', timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Room.wait('general', 'marlow', timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Agent::Profile.ping('wren', 'look', from: 'sable', room: 'general', root: @root)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end

  private

  def write_coord(team_room:)
    FileUtils.mkdir_p(File.join(@root, '.devin'))
    File.write(File.join(@root, '.devin', 'coord.json'), JSON.generate('teamRoom' => team_room))
  end
end
