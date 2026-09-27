require 'minitest/autorun'

require_relative 'common'

class BusTest < Minitest::Test
  include CoreTest

  def setup()
    setup_bus()
    @marlow = @bus.register('session-1', 'marlow')
    @wren = @bus.register('session-2', 'wren')
  end

  def teardown()
    teardown_bus()
  end

  def test_entries_carry_a_clock_and_optional_routing()
    entry = @bus.entry(from: @wren, text: 'hello', to: @marlow, room: @bus.room('general'))

    assert_equal 'wren', entry['from']
    assert_equal 'hello', entry['text']
    assert_equal 'marlow', entry['to']
    assert_equal 'general', entry['room']
    assert entry['ts'].positive?
    assert entry['id']
  end

  def test_jsonl_round_trips_and_skips_malformed_lines()
    path = File.join(@root, 'stream.jsonl')
    @bus.append(path, @bus.entry(from: @wren, text: 'first'))
    File.open(path, 'a') { |file| file.write("not json\n") }
    @bus.append(path, @bus.entry(from: @wren, text: 'second'))

    assert_equal %w[first second], @bus.read(path).map { |entry| entry['text'] }
    assert_empty @bus.read(File.join(@root, 'missing.jsonl'))
  end

  def test_stream_files_must_not_be_symlinks()
    dir = File.join(@root, 'streams')
    FileUtils.mkdir_p(dir)
    target = File.join(@root, 'target.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(dir, 'inbox.jsonl'))

    assert_raises(Bus::Error) { @bus.stream_path(dir, 'inbox.jsonl') }
  end

  def test_room_names_normalize_and_fall_back_to_the_team_room()
    write_config('teamRoom' => 'Market')

    assert_equal 'market', @bus.normalize('#Market')
    assert_equal 'market', @bus.normalize('')
    assert_raises(Bus::Error) { @bus.normalize('../secrets') }

    bare = Dir.mktmpdir('autonom-bare')
    assert_equal 'general', Bus.new(config: Config.load(bare), store: @store).team_room
    FileUtils.remove_entry(bare)
  end

  def test_reads_are_cursored_and_a_first_read_starts_with_a_window()
    path = File.join(@root, 'stream.jsonl')
    3.times { |index| @bus.append(path, @bus.entry(from: @wren, text: "line #{index}")) }

    first = @bus.read_stream(@marlow, 'inbox', @bus.read(path), limit: 2)

    assert_equal ['line 1', 'line 2'], first.map { |entry| entry['text'] }
    assert_equal 3, @bus.cursor(@marlow, 'inbox')
    assert_empty @bus.read_stream(@marlow, 'inbox', @bus.read(path))
  end
end
