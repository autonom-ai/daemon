require 'minitest/autorun'

require_relative 'common'

class InboxTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    @inbox = Bus.inbox(@wren)
    write_room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_dms_and_pings_are_profile_scoped()
    @inbox.dm('first', from: @marlow)
    @inbox.ping('look here', from: @marlow, room: room('general'))

    assert_equal ['first'], @inbox.messages.map { |entry| entry['text'] }
    assert_equal 'wren', @inbox.messages.first['to']
    assert_equal ['look here'], @inbox.pings.map { |entry| entry['text'] }
    assert_equal 'general', @inbox.pings.first['room']
    assert_empty Bus.inbox(@marlow).messages
  end

  def test_reading_a_stream_delivers_each_entry_once()
    @inbox.ping('look here', from: @marlow, room: room('general'))
    @inbox.ping('and here', from: @marlow)

    assert_equal ['look here', 'and here'], @inbox.read_pings().map { |ping| ping['text'] }
    assert_empty @inbox.read_pings()
  end

  def test_unread_does_not_advance_the_cursor()
    @inbox.dm('dm', from: @marlow)

    assert_equal 1, @inbox.unread.length
    assert_equal 1, @inbox.unread.length

    @inbox.read()

    assert_empty @inbox.unread
  end

  def test_a_dm_wakes_only_its_recipient()
    woken = Queue.new
    Thread.new do
      @inbox.wait(timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Bus.inbox(@marlow).wait(timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    @inbox.dm('psst', from: @marlow)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end

  def test_a_ping_interrupts_an_inbox_wait()
    woken = Queue.new
    Thread.new do
      @inbox.wait(timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Bus.inbox(@marlow).wait(timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    @inbox.ping('look', from: @marlow, room: room('general'))

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end
end
