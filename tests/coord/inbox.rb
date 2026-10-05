require 'minitest/autorun'

require_relative '../support'

class InboxTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    write_room('general')
    @room = room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_rooms_lists_what_exists()
    write_room('market')

    assert_equal %w[room:general room:market], Bus.rooms.map(&:stream)
  end

  def test_a_room_inbox_owns_its_name_and_path()
    assert_equal 'room:general', @room.stream
    assert File.file?(@room.messages_path)
    assert_nil room('nobody')
  end

  def test_messages_are_read_from_the_room_file()
    Bus.post(@room, 'hello', from: @marlow)

    assert_equal ['hello'], @room.inbox.messages.map { |entry| entry['text'] }
    assert_equal 'marlow', @room.inbox.messages.first['from']
  end

  def test_reads_are_cursored_per_profile_and_own_posts_are_not_unread()
    Bus.post(@room, 'first', from: @wren)
    Bus.post(@room, 'second', from: @wren)

    assert_equal 2, @room.inbox.unread(@marlow).length
    assert_equal ['first', 'second'], @room.inbox.read(@marlow).map { |entry| entry['text'] }
    assert_empty @room.inbox.unread(@marlow)

    # A profile's own posts are never its unread.
    assert_empty @room.inbox.unread(@wren)

    Bus.post(@room, 'third', from: @marlow)

    assert_equal ['third'], @room.inbox.unread(@wren).map { |entry| entry['text'] }

    Bus.dm(@wren, 'psst', from: @marlow)
    dms = Bus.dms_by_profile(@wren)

    assert_equal 1, dms.unread(@wren).length
    assert_equal 1, dms.unread(@wren).length
    dms.read(@wren)
    assert_empty dms.unread(@wren)
  end

  def test_a_room_post_wakes_every_waiter_in_the_room()
    woken = Queue.new
    waiters = [@marlow, @wren].map do |profile|
      Thread.new do
        @room.inbox.wait(profile, timeout: 5)
        woken << profile.name
      end
    end
    sleep 0.2

    Bus.post(@room, 'hello', from: @marlow)
    waiters.each { |waiter| waiter.join(3) }

    assert_equal %w[marlow wren], [woken.pop, woken.pop].sort
  end

  def test_a_ping_wakes_only_the_pinged_waiter()
    woken = Queue.new
    Thread.new do
      @room.inbox.wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      @room.inbox.wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Bus.ping(@wren, 'look', from: @marlow, room: @room)

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
      @room.inbox.wait(@wren, timeout: 5)
      writer.puts(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      writer.close
      exit!(0)
    end
    writer.close
    sleep 0.3

    Bus.post(@room, 'hello', from: @marlow)

    elapsed = IO.select([reader], nil, nil, 10) ? reader.gets.to_f : nil
    kill_child(child)
    Process.wait(child)

    refute_nil elapsed, 'the waiter in the other process was never woken'
    assert_operator elapsed, :<, 2
  ensure
    reader&.close
    kill_child(child)
  end

  def test_dms_and_pings_are_profile_scoped()
    Bus.dm(@wren, 'first', from: @marlow)
    Bus.ping(@wren, 'look here', from: @marlow, room: @room)

    dms = Bus.dms_by_profile(@wren)
    pings = Bus.pings_by_profile(@wren)

    assert_equal 'dms:wren', dms.stream_name
    assert_equal ['first'], dms.messages.map { |entry| entry['text'] }
    assert_equal 'wren', dms.messages.first['to']
    assert_equal 'pings:wren', pings.stream_name
    assert_equal ['look here'], pings.messages.map { |entry| entry['text'] }
    assert_equal 'room:general', pings.messages.first['room']
    assert_empty Bus.dms_by_profile(@marlow).messages
  end

  def test_reading_a_pings_stream_delivers_each_entry_once()
    Bus.ping(@wren, 'look here', from: @marlow, room: @room)
    Bus.ping(@wren, 'and here', from: @marlow)
    pings = Bus.pings_by_profile(@wren)

    assert_equal ['look here', 'and here'], pings.read(@wren).map { |ping| ping['text'] }
    assert_empty pings.read(@wren)
  end

  def test_a_dm_wakes_only_its_recipient()
    woken = Queue.new
    dms = Bus.dms_by_profile(@wren)
    Thread.new do
      dms.wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Bus.dms_by_profile(@marlow).wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Bus.dm(@wren, 'psst', from: @marlow)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end

  def test_a_ping_interrupts_a_dms_wait()
    woken = Queue.new
    dms = Bus.dms_by_profile(@wren)
    Thread.new do
      dms.wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Bus.dms_by_profile(@marlow).wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Bus.ping(@wren, 'look', from: @marlow, room: @room)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
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
