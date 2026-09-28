require 'minitest/autorun'

require_relative 'common'

class RoomTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    write_room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_rooms_lists_what_exists()
    write_room('market')

    assert_equal %w[room:general room:market], Bus.rooms.map(&:name)
  end

  def test_a_room_inbox_owns_its_name_and_path()
    assert_equal 'room:general', room('general').name
    assert File.file?(room('general').path)
    assert_nil room('nobody')
  end

  def test_messages_are_read_from_the_room_file()
    Bus.post(room('general'), 'hello', from: @marlow)

    assert_equal ['hello'], room('general').messages.map { |entry| entry['text'] }
    assert_equal 'marlow', room('general').messages.first['from']
    assert File.file?(File.join(@project, '.devin', 'autonom-coord', 'rooms', 'general.jsonl'))
  end

  def test_reading_a_room_is_cursored_per_profile()
    Bus.post(room('general'), 'first', from: @wren)
    Bus.post(room('general'), 'second', from: @wren)

    assert_equal 2, room('general').unread(@marlow).length
    assert_equal ['first', 'second'], room('general').read(@marlow).map { |entry| entry['text'] }
    assert_empty room('general').unread(@marlow)
    assert_equal 2, room('general').unread(@wren).length
  end

  def test_a_room_post_wakes_every_waiter_in_the_room()
    woken = Queue.new
    waiters = [@marlow, @wren].map do |profile|
      Thread.new do
        room('general').wait(profile, timeout: 5)
        woken << profile.name
      end
    end
    sleep 0.2

    Bus.post(room('general'), 'hello', from: @marlow)
    waiters.each { |waiter| waiter.join(3) }

    assert_equal %w[marlow wren], [woken.pop, woken.pop].sort
  end

  def test_a_ping_wakes_only_the_pinged_waiter()
    woken = Queue.new
    Thread.new do
      room('general').wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      room('general').wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Bus.ping(@wren, 'look', from: @marlow, room: room('general'))

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
      room('general').wait(@wren, timeout: 5)
      writer.puts(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      writer.close
      exit!(0)
    end
    writer.close
    sleep 0.3

    Bus.post(room('general'), 'hello', from: @marlow)

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
