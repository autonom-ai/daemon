require 'json'
require 'minitest/autorun'
require 'stringio'

require_relative '../support'
require_relative '../../source/coord/server'

class ServerTest < Minitest::Test
  include CoreTest

  def setup()
    setup_core()
    write_room('general')
    @server = Coord::Server.new
  end

  def teardown()
    teardown_core()
  end

  def test_profile_tools_share_session_mapping()
    responses = exchange(
      request(1, 'initialize', 'protocolVersion' => '2025-03-26'),
      { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' },
      request(2, 'tools/list'),
      call(3, 'set_profile', 'name' => 'Marlow', 'session_id' => 'session-1'),
      call(4, 'get_profile_status', 'session_id' => 'session-1')
    )

    listed_tools = responses.find { |response| response['id'] == 2 }.dig('result', 'tools')
    set_result = result(responses, 3)

    assert_equal %w[get_profiles get_profile_status set_profile post_message read_messages wait_for_message
                    list_rooms create_room delete_room set_room_involved add_room_admin remove_room_admin],
                 listed_tools.map { |tool| tool['name'] }
    assert_equal 'marlow', set_result['name']
    assert_equal(
      { 'name' => 'marlow', 'session' => 'session-1', 'online' => false },
      result(responses, 4)
    )
  end

  def test_chat_tools_route_rooms_dms_and_pings()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(
        3,
        'post_message',
        'text' => 'hello team',
        'room' => 'general',
        'ping' => ['wren'],
        'session_id' => 'session-1'
      ),
      call(4, 'read_messages', 'source' => 'pings', 'session_id' => 'session-2'),
      call(5, 'read_messages', 'source' => 'room', 'room' => 'general', 'session_id' => 'session-2'),
      call(6, 'post_message', 'text' => 'psst', 'to' => 'marlow', 'session_id' => 'session-2'),
      call(7, 'read_messages', 'source' => 'dms', 'session_id' => 'session-1'),
      call(8, 'post_message', 'text' => 'hi', 'room' => 'general', 'ping' => ['nobody'], 'session_id' => 'session-1')
    )

    assert_equal 'Sent message to room:general with 1 pings', result(responses, 3)['result']
    assert_equal ['hello team'], result(responses, 4)['messages'].map { |ping| ping['text'] }
    assert_equal ['hello team'], result(responses, 5)['messages'].map { |entry| entry['text'] }
    assert_equal 'marlow', result(responses, 5)['messages'].first['from']
    assert_equal 'Sent message to marlow with 0 pings', result(responses, 6)['result']
    assert_equal %w[wren marlow], result(responses, 7)['messages'].first.values_at('from', 'to')
    assert_equal ['psst'], result(responses, 7)['messages'].map { |entry| entry['text'] }
    assert responses.find { |response| response['id'] == 8 }.dig('result', 'isError')
  end

  def test_an_unknown_room_is_refused()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'post_message', 'text' => 'hello', 'room' => 'nowhere', 'session_id' => 'session-1')
    )

    assert responses.find { |response| response['id'] == 2 }.dig('result', 'isError')
  end

  def test_room_scoped_tools_require_a_room()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'post_message', 'text' => 'hello', 'session_id' => 'session-1'),
      call(3, 'read_messages', 'source' => 'room', 'session_id' => 'session-1'),
      call(4, 'wait_for_message', 'source' => 'room', 'timeout' => 1, 'session_id' => 'session-1')
    )

    assert responses.find { |response| response['id'] == 2 }.dig('result', 'isError')
    assert responses.find { |response| response['id'] == 3 }.dig('result', 'isError')
    assert responses.find { |response| response['id'] == 4 }.dig('result', 'isError')
  end

  def test_rooms_can_be_created_and_deleted_through_tools()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'create_room', 'name' => 'Market', 'session_id' => 'session-1'),
      call(3, 'create_room', 'name' => 'market', 'session_id' => 'session-1'),
      call(4, 'list_rooms', 'session_id' => 'session-1'),
      call(5, 'delete_room', 'name' => 'market', 'session_id' => 'session-1'),
      call(6, 'list_rooms', 'session_id' => 'session-1'),
      call(7, 'delete_room', 'name' => 'market', 'session_id' => 'session-1')
    )

    assert_equal 'room:market', result(responses, 2)['name']
    assert_equal 0, result(responses, 2)['count']
    assert responses.find { |response| response['id'] == 3 }.dig('result', 'isError')
    assert_includes result(responses, 4).map { |room| room['name'] }, 'room:market'
    assert_equal 'Deleted room room:market', result(responses, 5)['result']
    refute_includes result(responses, 6).map { |room| room['name'] }, 'room:market'
    assert responses.find { |response| response['id'] == 7 }.dig('result', 'isError')
  end

  def test_reads_are_cursored_and_list_rooms_reports_unread()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'post_message', 'text' => 'first', 'room' => 'general', 'session_id' => 'session-1'),
      call(4, 'read_messages', 'source' => 'room', 'room' => 'general', 'session_id' => 'session-2'),
      call(5, 'post_message', 'text' => 'second', 'room' => 'general', 'session_id' => 'session-1'),
      call(6, 'list_rooms', 'session_id' => 'session-2'),
      call(7, 'list_rooms', 'session_id' => 'session-1')
    )

    assert_equal ['first'], result(responses, 4)['messages'].map { |entry| entry['text'] }
    rooms = result(responses, 6)

    assert_equal ['room:general'], rooms.map { |room| room['name'] }
    assert_equal 2, rooms.first['count']
    assert_equal 1, rooms.first['unread']

    # marlow's own two posts are not his unread.
    assert_equal 0, result(responses, 7).first['unread']
  end

  def test_wait_for_message_returns_what_is_already_unread()
    exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'post_message', 'text' => 'first', 'room' => 'general', 'session_id' => 'session-1'),
      call(4, 'read_messages', 'source' => 'room', 'room' => 'general', 'session_id' => 'session-2'),
      call(5, 'post_message', 'text' => 'second', 'room' => 'general', 'session_id' => 'session-1')
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(
      call(
        6,
        'wait_for_message',
        'source' => 'room',
        'room' => 'general',
        'timeout' => 5,
        'session_id' => 'session-2'
      )
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.5
    assert_equal ['second'], result(responses, 6)['messages'].map { |entry| entry['text'] }
  end

  def test_wait_for_message_returns_empty_when_the_timeout_runs_out()
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))

    responses = exchange(
      call(
        2,
        'wait_for_message',
        'source' => 'room',
        'room' => 'general',
        'timeout' => 1,
        'session_id' => 'session-2'
      )
    )

    assert_empty result(responses, 2)['messages']
  end

  def test_a_ping_interrupts_a_room_wait()
    exchange(
      call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(2, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1')
    )
    pinger = Thread.new do
      sleep 0.3
      Bus.ping(profile('wren'), 'look', from: profile('marlow'), room: room('general'))
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(
      call(
        3,
        'wait_for_message',
        'source' => 'room',
        'room' => 'general',
        'timeout' => 5,
        'session_id' => 'session-2'
      )
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    pinger.join

    assert_operator elapsed, :<, 3
    assert_empty result(responses, 3)['messages']
  end

  def test_a_dm_wakes_a_dms_wait()
    exchange(
      call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(2, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1')
    )
    sender = Thread.new do
      sleep 0.3
      Bus.dm(profile('wren'), 'psst', from: profile('marlow'))
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(call(3, 'wait_for_message', 'source' => 'dms', 'timeout' => 5, 'session_id' => 'session-2'))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    sender.join

    assert_operator elapsed, :<, 3
    assert_equal ['psst'], result(responses, 3)['messages'].map { |entry| entry['text'] }
  end

  # The real shape of the bus: another session's MCP process writes the line,
  # so no signal can reach this one and only the file check can wake it.
  def test_a_room_line_written_by_another_process_wakes_a_room_wait()
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))
    writer = Thread.new do
      sleep 0.3
      append_line(room('general').path, 'from' => 'marlow', 'text' => 'late line')
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(
      call(
        2,
        'wait_for_message',
        'source' => 'room',
        'room' => 'general',
        'timeout' => 5,
        'session_id' => 'session-2'
      )
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    writer.join

    assert_operator elapsed, :<, 1.5
    assert_equal ['late line'], result(responses, 2)['messages'].map { |entry| entry['text'] }
  end

  def test_profile_status_reports_the_mapped_session_and_presence()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'get_profile_status', 'name' => 'wren', 'session_id' => 'session-1')
    )
    status = result(responses, 3)

    assert_equal 'wren', status['name']
    assert_equal 'session-2', status['session']
    refute status['online']

    with_online_session('session-2') do
      responses = exchange(call(4, 'get_profile_status', 'name' => 'wren', 'session_id' => 'session-1'))

      assert result(responses, 4)['online']
    end
  end

  def test_an_unregistered_session_has_no_status()
    assert_nil result(exchange(call(1, 'get_profile_status')), 1)
  end

  def test_get_profile_status_requires_a_known_profile()
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'get_profile_status', 'name' => 'nobody', 'session_id' => 'session-1')
    )

    assert responses.find { |response| response['id'] == 2 }.dig('result', 'isError')
  end

  def test_a_private_room_is_hidden_and_refuses_non_members()
    exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'set_room_involved', 'name' => 'general', 'involved' => ['marlow'], 'session_id' => 'session-1')
    )

    listed = result(exchange(call(4, 'list_rooms', 'session_id' => 'session-2')), 4)

    refute_includes listed.map { |room| room['name'] }, 'room:general'

    responses = exchange(
      call(5, 'post_message', 'text' => 'hi', 'room' => 'general', 'session_id' => 'session-2'),
      call(6, 'read_messages', 'source' => 'room', 'room' => 'general', 'session_id' => 'session-2')
    )

    assert responses.find { |response| response['id'] == 5 }.dig('result', 'isError')
    assert responses.find { |response| response['id'] == 6 }.dig('result', 'isError')

    sent = result(
      exchange(call(7, 'post_message', 'text' => 'hi', 'room' => 'general', 'session_id' => 'session-1')),
      7
    )

    assert_includes sent['result'], 'room:general'
  end

  def test_only_the_original_owner_changes_admins()
    exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'set_profile', 'name' => 'quill', 'session_id' => 'session-3'),
      call(4, 'add_room_admin', 'name' => 'general', 'profile' => 'wren', 'session_id' => 'session-1')
    )

    # An admin may administer the room's membership...
    administered = result(
      exchange(
        call(
          5,
          'set_room_involved',
          'name' => 'general',
          'involved' => %w[marlow wren],
          'session_id' => 'session-2'
        )
      ),
      5
    )

    assert_equal 'room:general', administered['name']

    # ...but only the original owner may change the admins.
    refused = exchange(
      call(
        6,
        'add_room_admin',
        'name' => 'general',
        'profile' => 'quill',
        'session_id' => 'session-2'
      )
    )

    assert refused.find { |response| response['id'] == 6 }.dig('result', 'isError')
  end

  def test_only_the_owner_or_admin_deletes_a_room()
    exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2')
    )

    refused = exchange(call(3, 'delete_room', 'name' => 'general', 'session_id' => 'session-2'))

    assert refused.find { |response| response['id'] == 3 }.dig('result', 'isError')

    deleted = result(exchange(call(4, 'delete_room', 'name' => 'general', 'session_id' => 'session-1')), 4)

    assert_equal 'Deleted room room:general', deleted['result']
  end

  private

  def exchange(*requests)
    input = StringIO.new(requests.map { |request| JSON.generate(request) }.join("\n"))
    output = StringIO.new
    @server.run(input: input, output: output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def request(id, method, params = {})
    { 'jsonrpc' => '2.0', 'id' => id, 'method' => method, 'params' => params }
  end

  def call(id, name, arguments = {})
    request(id, 'tools/call', 'name' => name, 'arguments' => arguments)
  end

  def result(responses, id)
    text = responses.find { |response| response['id'] == id }.dig('result', 'content', 0, 'text')
    JSON.parse(text)
  end

  # A line appended with no wake at all - what a different session's process does.
  def append_line(path, entry)
    FileUtils.mkdir_p(File.dirname(path))
    line = { 'id' => SecureRandom.uuid, 'ts' => (Time.now.to_f * 1000).round, **entry }
    File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
      file.write("#{JSON.generate(line)}\n")
    end
  end
end
