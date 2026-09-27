require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/coord/inbox'
require_relative '../source/coord/room'

class RoomTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_messages_are_workspace_scoped
    Room.post('general', 'hello', from: 'marlow', project: @root)

    entries = Room.messages('general', project: @root)

    assert_equal ['hello'], entries.map { |entry| entry['text'] }
    assert_equal 'marlow', entries.first['from']
    assert File.file?(File.join(@root, '.devin', 'autonom-coord', 'rooms', 'general.jsonl'))
    assert_empty Room.messages('other', project: @root)
  end

  def test_the_team_room_is_the_default_and_names_normalize
    write_config(team_room: 'market')

    Room.post(nil, 'hi', from: 'wren', project: @root)
    Room.post('#Market', 'again', from: 'wren', project: @root)

    assert_equal %w[hi again], Room.messages(nil, project: @root).map { |entry| entry['text'] }
    assert_equal %w[hi again], Room.messages('market', project: @root).map { |entry| entry['text'] }
  end

  def test_symlinked_room_files_are_refused
    rooms = File.join(@root, '.devin', 'autonom-coord', 'rooms')
    FileUtils.mkdir_p(rooms)
    target = File.join(@root, 'elsewhere.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(rooms, 'general.jsonl'))

    assert_raises(Bus::Error) { Room.messages('general', project: @root) }
    assert_raises(Bus::Error) { Room.post('general', 'hi', from: 'wren', project: @root) }
  end

  def test_reading_a_room_is_cursored_per_profile
    Room.post('general', 'first', from: 'wren', project: @root)
    Room.post('general', 'second', from: 'wren', project: @root)

    assert_equal 2, Room.unread('general', agent: 'marlow', project: @root, root: @root).length
    assert_equal ['first', 'second'], Room.read('general', agent: 'marlow', project: @root, root: @root).map { |entry| entry['text'] }
    assert_empty Room.unread('general', agent: 'marlow', project: @root, root: @root)
    assert_equal 2, Room.unread('general', agent: 'wren', project: @root, root: @root).length
  end

  def test_a_room_post_wakes_every_waiter_in_the_room
    woken = Queue.new
    waiters = %w[marlow wren].map do |agent|
      Thread.new do
        Room.wait('general', agent, timeout: 5, project: @root)
        woken << agent
      end
    end
    sleep 0.2

    Room.post('general', 'hello', from: 'sable', project: @root)
    waiters.each { |waiter| waiter.join(3) }

    assert_equal %w[marlow wren], [woken.pop, woken.pop].sort
  end

  def test_a_ping_wakes_only_the_pinged_waiter
    woken = Queue.new
    Thread.new do
      Room.wait('general', 'wren', timeout: 5, project: @root)
      woken << 'wren'
    end
    other = Thread.new do
      Room.wait('general', 'marlow', timeout: 1, project: @root)
      woken << 'marlow'
    end
    sleep 0.2

    Inbox.ping('wren', 'look', from: 'sable', room: 'general', root: @root)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end

  # One process waits, another writes: a signal cannot cross the boundary, so
  # the watched file is the only thing that can wake the waiter.
  def test_a_waiter_in_another_process_is_woken_by_the_file
    skip 'fork is unavailable' unless Process.respond_to?(:fork)
    reader, writer = IO.pipe
    child = fork do
      reader.close
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Room.wait('general', 'wren', timeout: 5, project: @root)
      writer.puts(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      writer.close
      exit!(0)
    end
    writer.close
    sleep 0.3

    Room.post('general', 'hello', from: 'sable', project: @root)

    elapsed = IO.select([reader], nil, nil, 10) ? reader.gets.to_f : nil
    kill_child(child)
    Process.wait(child)

    refute_nil elapsed, 'the waiter in the other process was never woken'
    assert_operator elapsed, :<, 2
  ensure
    reader&.close
    kill_child(child)
  end

  private

  # The child may already be gone by the time the test ends; a signal it cannot
  # receive is not an error, and leaving it behind is.
  def kill_child(child)
    Process.kill('KILL', child) if child
  rescue Errno::ESRCH
    nil
  end

  def write_config(team_room:)
    FileUtils.mkdir_p(File.join(@root, '.devin'))
    File.write(File.join(@root, '.devin', 'autonom-config.json'), JSON.generate('teamRoom' => team_room))
  end
end
