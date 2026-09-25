require 'json'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

require_relative '../source/core/server'

class ServerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
    @server = Agent::Server.new(root: @root, project: @root)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_profile_tools_share_session_mapping
    responses = exchange(
      request(1, 'initialize', 'protocolVersion' => '2025-03-26'),
      { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' },
      request(2, 'tools/list'),
      call(3, 'set_profile', 'name' => 'Marlow', 'session_id' => 'session-1'),
      call(4, 'get_profile', 'session_id' => 'session-1')
    )

    listed_tools = responses.find { |response| response['id'] == 2 }.dig('result', 'tools')
    set_result = result(responses, 3)
    get_result = result(responses, 4)

    assert_equal %w[get_profiles get_profile set_profile send_message read_messages wait_for_message list_rooms get_heartbeat],
                 listed_tools.map { |tool| tool['name'] }
    assert_equal 'marlow', set_result['name']
    assert_equal set_result, get_result
  end

  def test_chat_tools_route_rooms_dms_and_pings
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'send_message', 'text' => 'hello team', 'room' => 'general', 'ping' => ['wren'], 'session_id' => 'session-1'),
      call(4, 'read_messages', 'source' => 'pings', 'session_id' => 'session-2'),
      call(5, 'read_messages', 'source' => 'room', 'session_id' => 'session-2'),
      call(6, 'send_message', 'text' => 'psst', 'to' => 'marlow', 'session_id' => 'session-2'),
      call(7, 'read_messages', 'source' => 'inbox', 'session_id' => 'session-1'),
      call(8, 'read_messages', 'source' => 'pings', 'session_id' => 'session-2'),
      call(9, 'send_message', 'text' => 'hi', 'ping' => ['nobody'], 'session_id' => 'session-1'),
      call(10, 'read_messages', 'source' => 'pings', 'session_id' => 'session-1')
    )

    sent = result(responses, 3)

    assert_equal 'general', sent['room']
    assert_equal 'marlow', sent['entry']['from']
    assert_equal ['wren'], sent['pinged']
    assert_equal ['hello team'], result(responses, 4)['messages'].map { |ping| ping['text'] }
    assert_equal ['hello team'], result(responses, 5)['messages'].map { |entry| entry['text'] }
    assert_equal %w[wren marlow], result(responses, 6)['entry'].values_at('from', 'to')
    assert_equal ['psst'], result(responses, 7)['messages'].map { |entry| entry['text'] }
    assert_empty result(responses, 8)['messages']
    assert responses.find { |response| response['id'] == 9 }.dig('result', 'isError')
    assert_empty result(responses, 10)['messages']
  end

  def test_reads_are_cursored_and_list_rooms_reports_unread
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'send_message', 'text' => 'first', 'session_id' => 'session-1'),
      call(4, 'read_messages', 'source' => 'room', 'session_id' => 'session-2'),
      call(5, 'send_message', 'text' => 'second', 'session_id' => 'session-1'),
      call(6, 'list_rooms', 'session_id' => 'session-2'),
      call(7, 'list_rooms', 'session_id' => 'session-1')
    )

    assert_equal ['first'], result(responses, 4)['messages'].map { |entry| entry['text'] }
    rooms = result(responses, 6)

    assert_equal ['general'], rooms.map { |room| room['name'] }
    assert_equal 2, rooms.first['count']
    assert_equal 1, rooms.first['unread']
    assert_equal 2, result(responses, 7).first['unread']
  end

  def test_wait_for_message_wakes_on_a_new_room_line
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))
    writer = Thread.new do
      sleep 0.3
      Room.post('general', 'late line', from: 'marlow', root: @root)
    end

    responses = exchange(call(2, 'wait_for_message', 'source' => 'room', 'timeout' => 5, 'session_id' => 'session-2'))
    writer.join

    assert_equal ['late line'], result(responses, 2)['messages'].map { |entry| entry['text'] }
  end

  def test_wait_for_message_returns_what_is_already_unread
    exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'send_message', 'text' => 'first', 'session_id' => 'session-1'),
      call(4, 'read_messages', 'source' => 'room', 'session_id' => 'session-2'),
      call(5, 'send_message', 'text' => 'second', 'session_id' => 'session-1')
    )

    responses = exchange(call(6, 'wait_for_message', 'source' => 'room', 'timeout' => 1, 'session_id' => 'session-2'))

    assert_equal ['second'], result(responses, 6)['messages'].map { |entry| entry['text'] }
  end

  def test_wait_for_message_returns_empty_when_the_timeout_runs_out
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))

    responses = exchange(call(2, 'wait_for_message', 'source' => 'room', 'timeout' => 1, 'session_id' => 'session-2'))

    assert_empty result(responses, 2)['messages']
  end

  def test_a_ping_interrupts_a_room_wait
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))
    pinger = Thread.new do
      sleep 0.3
      Agent::Profile.ping('wren', 'look', from: 'marlow', room: 'general', root: @root)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(call(2, 'wait_for_message', 'source' => 'room', 'timeout' => 5, 'session_id' => 'session-2'))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    pinger.join

    assert_operator elapsed, :<, 3
    assert_empty result(responses, 2)['messages']
  end

  def test_a_dm_wakes_an_inbox_wait
    exchange(call(1, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'))
    sender = Thread.new do
      sleep 0.3
      Agent::Profile.dm('wren', 'psst', from: 'marlow', root: @root)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    responses = exchange(call(2, 'wait_for_message', 'source' => 'inbox', 'timeout' => 5, 'session_id' => 'session-2'))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    sender.join

    assert_operator elapsed, :<, 3
    assert_equal ['psst'], result(responses, 2)['messages'].map { |entry| entry['text'] }
  end

  def test_get_heartbeat_reports_another_profile
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'set_profile', 'name' => 'wren', 'session_id' => 'session-2'),
      call(3, 'get_heartbeat', 'name' => 'wren', 'session_id' => 'session-1')
    )

    beat = result(responses, 3)

    assert_equal 'wren', beat['name']
    assert beat['lastHeartbeat'].positive?
    assert beat['online']
  end

  def test_get_heartbeat_requires_a_known_profile
    responses = exchange(
      call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'),
      call(2, 'get_heartbeat', 'name' => 'nobody', 'session_id' => 'session-1')
    )

    assert responses.find { |response| response['id'] == 2 }.dig('result', 'isError')
  end

  def test_a_plain_call_refreshes_the_heartbeat
    exchange(call(1, 'set_profile', 'name' => 'marlow', 'session_id' => 'session-1'))
    file = File.join(@root, 'agents', 'marlow', 'heartbeat.json')
    File.write(file, '{"ts":0}')

    exchange(call(2, 'get_profiles', 'session_id' => 'session-1'))

    assert JSON.parse(File.read(file))['ts'].positive?
  end

  def test_an_unregistered_session_stamps_nobody
    exchange(call(1, 'get_profiles'))

    assert_empty Dir.glob(File.join(@root, 'agents', '*', 'heartbeat.json'))
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
    responses.find { |response| response['id'] == id }.dig('result', 'structuredContent')
  end
end
