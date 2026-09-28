require 'minitest/autorun'

require_relative 'common'

class InboxTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    @marlow = ProfileStore.register_profile('marlow', 'session-1')
    @wren = ProfileStore.register_profile('wren', 'session-2')
    @dms = Bus.dms_by_profile(@wren)
    @pings = Bus.pings_by_profile(@wren)
    write_room('general')
  end

  def teardown()
    teardown_core()
  end

  def test_dms_and_pings_are_profile_scoped()
    Bus.dm(@wren, 'first', from: @marlow)
    Bus.ping(@wren, 'look here', from: @marlow, room: room('general'))

    assert_equal 'dms:wren', @dms.name
    assert_equal ['first'], @dms.messages.map { |entry| entry['text'] }
    assert_equal 'wren', @dms.messages.first['to']
    assert_equal 'pings:wren', @pings.name
    assert_equal ['look here'], @pings.messages.map { |entry| entry['text'] }
    assert_equal 'room:general', @pings.messages.first['room']
    assert_empty Bus.dms_by_profile(@marlow).messages
  end

  def test_reading_a_stream_delivers_each_entry_once()
    Bus.ping(@wren, 'look here', from: @marlow, room: room('general'))
    Bus.ping(@wren, 'and here', from: @marlow)

    assert_equal ['look here', 'and here'], @pings.read(@wren).map { |ping| ping['text'] }
    assert_empty @pings.read(@wren)
  end

  def test_unread_does_not_advance_the_cursor()
    Bus.dm(@wren, 'dm', from: @marlow)

    assert_equal 1, @dms.unread(@wren).length
    assert_equal 1, @dms.unread(@wren).length

    @dms.read(@wren)

    assert_empty @dms.unread(@wren)
  end

  def test_a_dm_wakes_only_its_recipient()
    woken = Queue.new
    Thread.new do
      @dms.wait(@wren, timeout: 5)
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
    Thread.new do
      @dms.wait(@wren, timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Bus.dms_by_profile(@marlow).wait(@marlow, timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Bus.ping(@wren, 'look', from: @marlow, room: room('general'))

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end
end
