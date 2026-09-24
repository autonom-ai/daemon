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

    assert_equal %w[get_profiles get_profile set_profile send_message read_messages],
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
