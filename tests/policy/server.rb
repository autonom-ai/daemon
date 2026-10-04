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

    assert_equal %w[check_policy], names
  end

  def test_secondary_policy_tools_are_gone()
    responses = exchange(
      call(
        1,
        'set_secondary_policy',
        'path' => room('general').policy_path,
        'policy' => { 'rules' => [] },
        'session_id' => 'session-1'
      )
    )

    assert responses.first.dig('result', 'isError')
  end

  def test_check_policy_applies_the_callers_profile_policy()
    File.write(room('general').policy_path, "rules:\n  - action: deny\n    reason: room\n")
    profile('marlow').policy = room('general').policy_path
    checked = result(
      exchange(
        call(
          1,
          'check_policy',
          'tool_name' => 'exec',
          'tool_input' => { 'command' => 'git status' },
          'session_id' => 'session-1'
        )
      ),
      1
    )

    assert checked['denied']
    assert_equal 'room', checked['reason']
    assert_equal room('general').policy_path, checked['secondary']
  end

  def test_check_policy_ignores_a_supplied_secondary_path()
    File.write(room('general').policy_path, "rules:\n  - action: deny\n    reason: room\n")
    checked = result(
      exchange(
        call(
          1,
          'check_policy',
          'tool_name' => 'exec',
          'secondary' => room('general').policy_path,
          'session_id' => 'session-1'
        )
      ),
      1
    )

    refute checked['denied']
    assert_nil checked['secondary']
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
