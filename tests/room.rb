require 'minitest/autorun'

require_relative 'common'

class RoomTest < Minitest::Test
  include CoreTest

  def setup()
    setup_bus()
    @marlow = @bus.register('session-1', 'marlow')
    @wren = @bus.register('session-2', 'wren')
    @room = @bus.room('general')
  end

  def teardown()
    teardown_bus()
  end

  def test_messages_are_workspace_scoped()
    @room.post('hello', from: @marlow)

    assert_equal ['hello'], @room.messages.map { |entry| entry['text'] }
    assert_equal 'marlow', @room.messages.first['from']
    assert File.file?(File.join(@project, '.devin', 'autonom-coord', 'rooms', 'general.jsonl'))
    assert_empty @bus.room('other').messages
  end

  def test_the_team_room_is_the_default_and_names_normalize()
    write_config('teamRoom' => 'market')

    @bus.room('').post('hi', from: @wren)
    @bus.room('#Market').post('again', from: @wren)

    assert_equal %w[hi again], @bus.room('market').messages.map { |entry| entry['text'] }
  end

  def test_symlinked_room_files_are_refused()
    rooms = File.join(@project, '.devin', 'autonom-coord', 'rooms')
    FileUtils.mkdir_p(rooms)
    target = File.join(@project, 'elsewhere.jsonl')
    File.write(target, '')
    File.symlink(target, File.join(rooms, 'general.jsonl'))

    assert_raises(Bus::Error) { @room.messages }
    assert_raises(Bus::Error) { @room.post('hi', from: @wren) }
  end

  def test_reading_a_room_is_cursored_per_profile()
    @room.post('first', from: @wren)
    @room.post('second', from: @wren)

    assert_equal 2, @room.unread(@marlow).length
    assert_equal ['first', 'second'], @room.read(@marlow).map { |entry| entry['text'] }
    assert_empty @room.unread(@marlow)
    assert_equal 2, @room.unread(@wren).length
  end

  def test_a_room_post_wakes_every_waiter_in_the_room()
    woken = Queue.new
    waiters = [@marlow, @wren].map do |profile|
      Thread.new do
        @room.wait(profile, timeout: 5)
        woken << profile.name
      end
    end
    sleep 0.2

    @room.post('hello', from: @marlow)
    waiters.each { |waiter| waiter.join(3) }

    assert_equal %w[marlow wren], [woken.pop, woken.pop].sort
  end

  def test_a_ping_wakes_only_the_pinged_waiter()
    woken = Queue.new
    Thread.new do
      @room.wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      @room.wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    @wren.inbox.ping('look', from: @marlow, room: @room)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end

  # One process waits, another writes: a signal cannot cross the boundary, so
  # the watched file is the only thing that can wake the waiter.
  def test_a_waiter_in_another_process_is_woken_by_the_file()
    skip 'fork is unavailable' unless Process.respond_to?(:fork)
    reader, writer = IO.pipe
    child = fork do
      reader.close
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @room.wait(@wren, timeout: 5)
      writer.puts(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      writer.close
      exit!(0)
    end
    writer.close
    sleep 0.3

    @room.post('hello', from: @marlow)

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
end
