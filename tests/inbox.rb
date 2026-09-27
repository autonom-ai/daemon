require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/coord/inbox'

class InboxTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('autonom')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_dms_and_pings_are_profile_scoped
    Inbox.dm('marlow', 'first', from: 'wren', root: @root)
    Inbox.ping('marlow', 'look here', from: 'wren', room: 'general', root: @root)

    dms = Inbox.messages('marlow', root: @root)
    pings = Inbox.pings('marlow', root: @root)

    assert_equal ['first'], dms.map { |entry| entry['text'] }
    assert_equal 'marlow', dms.first['to']
    assert_equal ['look here'], pings.map { |entry| entry['text'] }
    assert_equal 'general', pings.first['room']
    assert File.file?(File.join(@root, 'agents', 'marlow', 'inbox.jsonl'))
    assert_empty Inbox.messages('wren', root: @root)
  end

  def test_read_pings_delivers_each_ping_once
    Inbox.ping('marlow', 'look here', from: 'wren', room: 'general', root: @root)
    Inbox.ping('marlow', 'and here', from: 'sable', root: @root)

    assert_equal ['look here', 'and here'], Inbox.read_pings('marlow', root: @root).map { |ping| ping['text'] }
    assert_empty Inbox.read_pings('marlow', root: @root)
    assert_equal 2, Inbox.pings('marlow', root: @root).length
  end

  def test_reads_advance_cursors_and_a_first_read_starts_with_a_window
    3.times { |index| Inbox.dm('marlow', "dm #{index}", from: 'wren', root: @root) }

    first = Inbox.read('marlow', limit: 2, root: @root)

    assert_equal ['dm 1', 'dm 2'], first.map { |entry| entry['text'] }
    assert_empty Inbox.read('marlow', root: @root)

    Inbox.dm('marlow', 'dm 3', from: 'wren', root: @root)
    assert_equal ['dm 3'], Inbox.read('marlow', root: @root).map { |entry| entry['text'] }
  end

  def test_unread_reads_do_not_advance_the_cursor
    Inbox.dm('marlow', 'dm', from: 'wren', root: @root)

    assert_equal 1, Inbox.unread('marlow', root: @root).length
    assert_equal 1, Inbox.unread('marlow', root: @root).length
    assert_equal 1, Inbox.read('marlow', root: @root).length
    assert_empty Inbox.unread('marlow', root: @root)
  end

  def test_chat_names_are_validated
    assert_raises(ProfileStore::Error) { Inbox.dm('../wren', 'hi', from: 'marlow', root: @root) }
    assert_raises(ProfileStore::Error) { Inbox.ping('..', 'hi', from: 'marlow', root: @root) }
  end

  def test_a_dm_wakes_only_its_recipient
    woken = Queue.new
    Thread.new do
      Inbox.wait('wren', timeout: 5)
      woken << 'wren'
    end
    other = Thread.new do
      Inbox.wait('marlow', timeout: 1)
      woken << 'marlow'
    end
    sleep 0.2

    Inbox.dm('wren', 'psst', from: 'sable', root: @root)

    assert_equal 'wren', woken.pop
    assert woken.empty?
  ensure
    other&.join(2)
  end
end
