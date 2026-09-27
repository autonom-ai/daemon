require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/coord/bus'

class BusTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('autonom-project')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_entries_carry_a_clock_and_optional_routing
    entry = Bus.entry(from: 'wren', text: 'hello', to: 'marlow')

    assert_equal 'wren', entry['from']
    assert_equal 'hello', entry['text']
    assert_equal 'marlow', entry['to']
    assert_nil entry['room']
    assert entry['ts'].positive?
    assert entry['id']
  end

  def test_jsonl_round_trips_and_skips_malformed_lines
    path = File.join(@root, 'stream.jsonl')
    Bus.append(path, Bus.entry(from: 'wren', text: 'first'))
    File.open(path, 'a') { |file| file.write("not json\n") }
    Bus.append(path, Bus.entry(from: 'wren', text: 'second'))

    assert_equal %w[first second], Bus.read(path).map { |entry| entry['text'] }
    assert_empty Bus.read(File.join(@root, 'missing.jsonl'))
  end

  def test_stream_files_must_not_be_symlinks
    dir = File.join(@root, 'streams')
    FileUtils.mkdir_p(dir)
    target = File.join(@root, 'target.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(dir, 'inbox.jsonl'))

    assert_raises(Bus::Error) { Bus.stream_path(dir, 'inbox.jsonl') }
  end

  def test_room_names_normalize_and_fall_back_to_the_team_room
    write_config('teamRoom' => 'Market')
    bare = File.join(@root, 'bare')
    FileUtils.mkdir_p(bare)

    assert_equal 'market', Bus.normalize('#Market', project: @project)
    assert_equal 'market', Bus.normalize('', project: @project)
    assert_equal 'general', Bus.team_room(project: bare)
    assert_raises(Bus::Error) { Bus.normalize('../secrets', project: @project) }
  end

  def test_reads_are_cursored_and_a_first_read_starts_with_a_window
    3.times { |index| Bus.append(stream, Bus.entry(from: 'wren', text: "line #{index}")) }

    first = Bus.read_stream('marlow', 'inbox', Bus.read(stream), limit: 2, root: @root)

    assert_equal ['line 1', 'line 2'], first.map { |entry| entry['text'] }
    assert_equal 3, Bus.cursor('marlow', 'inbox', root: @root)
    assert_empty Bus.read_stream('marlow', 'inbox', Bus.read(stream), root: @root)

    Bus.append(stream, Bus.entry(from: 'wren', text: 'line 3'))
    assert_equal ['line 3'], Bus.read_stream('marlow', 'inbox', Bus.read(stream), root: @root).map { |entry| entry['text'] }
  end

  private

  def stream
    File.join(@root, 'agents', 'marlow', 'inbox.jsonl')
  end

  def write_config(values)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(values))
  end
end
