require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/core/room'

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

  private

  def write_coord(team_room:)
    FileUtils.mkdir_p(File.join(@root, '.devin'))
    File.write(File.join(@root, '.devin', 'coord.json'), JSON.generate('teamRoom' => team_room))
  end
end
