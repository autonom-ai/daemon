require 'json'
require 'minitest/autorun'
require 'stringio'

require_relative '../support'
require_relative '../../source/policy/server'

class PolicyServerTest < Minitest::Test
  include CoreTest

  class FakeDecision
    def harmful?(_state, _question)
      false
    end
  end

  def setup()
    setup_core()
    ProfileStore.register_profile('marlow', 'session-1')
    ProfileStore.register_profile('wren', 'session-2')
    write_room('general')
    @server = Policy::Server.new(decision: FakeDecision.new)
  end

  def teardown()
    teardown_core()
  end

  def test_the_server_lists_policy_tools()
    responses = exchange(request(1, 'tools/list'))
    names = responses.first.dig('result', 'tools').map { |tool| tool['name'] }

    assert_equal %w[check_policy set_secondary_policy list_secondary_policies remove_secondary_policy], names
  end

  def test_secondary_policy_tools_manage_existing_policy_paths()
    path = room('general').policy_path
    responses = exchange(
      call(
        1,
        'set_secondary_policy',
        'path' => path,
        'policy' => { 'rules' => [] },
        'session_id' => 'session-1'
      ),
      call(2, 'list_secondary_policies', 'directory' => Workspace.rooms_dir, 'session_id' => 'session-1'),
      call(3, 'remove_secondary_policy', 'path' => path, 'session_id' => 'session-1'),
      call(4, 'list_secondary_policies', 'directory' => Workspace.rooms_dir, 'session_id' => 'session-1')
    )

    assert_equal path, result(responses, 1)['path']
    assert_equal [path], result(responses, 2).map { |entry| entry['path'] }
    assert result(responses, 3)['removed']
    assert_empty result(responses, 4)
  end

  def test_secondary_policy_tools_preserve_room_administration()
    responses = exchange(
      call(
        1,
        'set_secondary_policy',
        'path' => room('general').policy_path,
        'policy' => { 'rules' => [] },
        'session_id' => 'session-2'
      ),
      call(2, 'remove_secondary_policy', 'path' => room('general').policy_path, 'session_id' => 'session-2')
    )

    assert responses.all? { |response| response.dig('result', 'isError') }
  end

  def test_listing_does_not_read_or_reveal_hidden_room_policies()
    write_room('secret', involved: ['marlow'])
    File.write(room('secret').policy_path, 'invalid: [')
    listed = result(
      exchange(call(1, 'list_secondary_policies', 'directory' => Workspace.rooms_dir, 'session_id' => 'session-2')),
      1
    )

    assert_equal [room('general').policy_path], listed.map { |entry| entry['path'] }
  end

  def test_check_policy_uses_the_secondary_path_supplied_by_the_hook()
    path = room('general').policy_path
    Policy.set_secondary(path, 'rules' => [{ 'action' => 'deny', 'reason' => 'room' }])
    checked = result(
      exchange(
        call(
          1,
          'check_policy',
          'tool_name' => 'exec',
          'tool_input' => { 'command' => 'git status' },
          'secondary' => path,
          'session_id' => 'session-1'
        )
      ),
      1
    )

    assert checked['denied']
    assert_equal 'room', checked['reason']
    assert_equal path, checked['secondary']
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
end
