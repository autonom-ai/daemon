require 'minitest/autorun'

require_relative 'common'

class BusTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register('session-1', 'marlow')
    @wren = ProfileStore.register('session-2', 'wren')
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
    assert_equal 'general', entry['room']
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

  def test_a_rooms_first_line_is_its_description()
    write_room('market', 'Pricing and market data.')

    assert_equal 'Pricing and market data.', Bus.head(Bus.room_path('market'))['description']
  end

  def test_stream_files_must_not_be_symlinks()
    dir = File.join(@root, 'streams')
    FileUtils.mkdir_p(dir)
    target = File.join(@root, 'target.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(dir, 'inbox.jsonl'))

    assert_raises(Bus::Error) { Bus.stream_path(dir, 'inbox.jsonl') }
  end

  def test_room_names_normalize_and_a_bare_name_means_the_default_room()
    write_config('defaultRoom' => 'Market')

    assert_equal 'market', Bus.room_name('#Market')
    assert_equal 'market', Bus.room_name('')
    assert_equal 'market', Bus.default_room
    assert_raises(Bus::Error) { Bus.room_name('../secrets') }
  end

  def test_reads_are_cursored_and_a_first_read_starts_with_a_window()
    path = File.join(@root, 'stream.jsonl')
    3.times { |index| Bus.append(path, Bus.entry(from: @wren, text: "line #{index}")) }

    first = Bus.read_stream(@marlow, 'inbox', Bus.read(path), limit: 2)

    assert_equal ['line 1', 'line 2'], first.map { |entry| entry['text'] }
    assert_equal 3, Bus.cursor(@marlow, 'inbox')
    assert_empty Bus.read_stream(@marlow, 'inbox', Bus.read(path))
  end

  def test_unread_is_the_profiles_inbox_pings_and_rooms()
    write_room('general')
    Bus.inbox(@wren).dm('hello', from: @marlow)
    Bus.inbox(@wren).ping('look', from: @marlow, room: room('general'))
    room('general').post('team line', from: @marlow)

    unread = Bus.unread(@wren)

    assert_equal ['hello'], unread['inbox'].map { |entry| entry['text'] }
    assert_equal ['look'], unread['pings'].map { |entry| entry['text'] }
    assert_equal ['team line'], unread['rooms']['general'].map { |entry| entry['text'] }
  end
end
