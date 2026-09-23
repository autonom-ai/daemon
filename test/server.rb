require 'json'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

require_relative '../source/core/server'

class ServerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('agent-coord')
    @server = Agent::Server.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_profile_tools_share_session_mapping
    requests = [
      { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => { 'protocolVersion' => '2025-03-26' } },
      { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' },
      { 'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/list' },
      {
        'jsonrpc' => '2.0',
        'id' => 3,
        'method' => 'tools/call',
        'params' => {
          'name' => 'set_profile',
          'arguments' => { 'name' => 'Marlow', 'session_id' => 'session-1' }
        }
      },
      {
        'jsonrpc' => '2.0',
        'id' => 4,
        'method' => 'tools/call',
        'params' => { 'name' => 'get_profile', 'arguments' => { 'session_id' => 'session-1' } }
      }
    ]
    input = StringIO.new(requests.map { |request| JSON.generate(request) }.join("\n"))
    output = StringIO.new

    @server.run(input: input, output: output)
    responses = output.string.lines.map { |line| JSON.parse(line) }
    listed_tools = responses.find { |response| response['id'] == 2 }.dig('result', 'tools')
    set_result = responses.find { |response| response['id'] == 3 }.dig('result', 'structuredContent')
    get_result = responses.find { |response| response['id'] == 4 }.dig('result', 'structuredContent')

    assert_equal %w[get_profiles get_profile set_profile], listed_tools.map { |tool| tool['name'] }
    assert_equal 'marlow', set_result['name']
    assert_equal set_result, get_result
    assert_equal 4, responses.length
  end
end
