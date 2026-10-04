require 'minitest/autorun'

require_relative '../support'

class BusTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
  end

  def teardown()
    teardown_core()
  end

  def test_entries_carry_a_clock_and_optional_routing()
    write_room('general')
    entry = Bus.entry(from: @wren, text: 'hello', to: @marlow, room: room('general'))

    assert_equal 'wren', entry['from']
    assert_equal 'hello', entry['text']
    assert_equal 'marlow', entry['to']
    assert_equal 'room:general', entry['room']
    assert entry['ts'].positive?
    assert entry['id']
  end

  def test_jsonl_round_trips_and_skips_malformed_lines()
    path = File.join(@root, 'stream.jsonl')
    Bus.append(path, Bus.entry(from: @wren, text: 'first'))
    File.open(path, 'a') { |file| file.write("not json\n") }
    Bus.append(path, Bus.entry(from: @wren, text: 'second'))

    assert_equal %w[first second], Bus.read(path).map { |entry| entry['text'] }
    assert_empty Bus.read(File.join(@root, 'missing.jsonl'))
  end

  def test_stream_files_must_not_be_symlinks()
    dir = File.join(@root, 'streams')
    FileUtils.mkdir_p(dir)
    target = File.join(@root, 'target.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(dir, 'inbox.jsonl'))

    assert_raises(Bus::Error) { Bus.stream_path(dir, 'inbox.jsonl') }
  end

  def test_room_names_normalize_and_look_up_an_existing_room()
    write_room('market')

    assert_equal 'room:market', Bus.room_by_name('#Market').stream
    assert_nil Bus.room_by_name('')
    assert_nil Bus.room_by_name('../secrets')
  end

  def test_rooms_can_be_created_and_deleted()
    created = Bus.create_room('#Market', owner: 'marlow')

    assert_equal 'room:market', created.stream
    assert File.exist?(created.path)
    assert_equal 'room:market', Bus.room_by_name('market').stream

    Bus.delete_room('market')

    assert_nil Bus.room_by_name('market')
    refute File.exist?(created.path)
  end

  def test_room_creation_refuses_bad_and_duplicate_names()
    write_room('general')

    assert_raises(Bus::Error) { Bus.create_room('../secrets', owner: 'marlow') }
    assert_raises(Bus::Error) { Bus.create_room('general', owner: 'marlow') }
  end

  def test_room_deletion_requires_an_existing_room()
    assert_raises(Bus::Error) { Bus.delete_room('nowhere') }
  end

  def test_reads_are_cursored_and_a_first_read_starts_with_a_window()
    path = File.join(@root, 'stream.jsonl')
    3.times { |index| Bus.append(path, Bus.entry(from: @wren, text: "line #{index}")) }

    first = Bus.read_stream(@marlow, 'dms:marlow', Bus.read(path), limit: 2)

    assert_equal ['line 1', 'line 2'], first.map { |entry| entry['text'] }
    assert_equal 3, Bus.cursor(@marlow, 'dms:marlow')
    assert_empty Bus.read_stream(@marlow, 'dms:marlow', Bus.read(path))
  end

  def test_unread_is_the_profiles_pings_dms_and_rooms()
    write_room('general')
    Bus.dm(@wren, 'hello', from: @marlow)
    Bus.ping(@wren, 'look', from: @marlow, room: room('general'))
    Bus.post(room('general'), 'team line', from: @marlow)

    unread = Bus.unread(@wren)

    assert_equal ['hello'], unread['dms'].map { |entry| entry['text'] }
    assert_equal ['look'], unread['pings'].map { |entry| entry['text'] }
    assert_equal ['team line'], unread['rooms']['room:general'].map { |entry| entry['text'] }
    assert_equal room('general').policy_path, @marlow.policy
  end
end
