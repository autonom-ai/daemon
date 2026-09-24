require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/core/hooks'

class HooksTest < Minitest::Test
  class FakeJev
    attr_reader :calls

    def initialize(harmful: false)
      @harmful = harmful
      @calls = 0
    end

    def harmful?(**_arguments)
      @calls += 1
      @harmful
    end
  end

  def setup
    @root = Dir.mktmpdir('agent-coord')
    @jev = FakeJev.new
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_direct_cross_profile_read_is_denied_before_jev
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')

    result = Agent::Hooks.call(event('read', 'file_path' => path), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_mapping_file_write_is_denied_before_jev
    path = File.join(@root, 'agents', 'sessions.json')

    result = Agent::Hooks.call(event('write', 'file_path' => path), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_patch_to_another_profile_is_denied_before_jev
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    patch = ['*** Begin Patch', "*** Update File: #{path}", '+note', '*** End Patch'].join("\n")

    result = Agent::Hooks.call(event('apply_patch', 'patch' => patch), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_shell_redirection_to_another_profile_is_denied_before_jev
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')

    result = Agent::Hooks.call(
      event('exec', 'command' => "printf note > #{path}"),
      jev: @jev,
      root: @root
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_recursive_search_of_profile_root_is_denied_before_jev
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren', 'memories'))
    result = Agent::Hooks.call(
      event('grep', 'pattern' => 'memory', 'path' => @root),
      jev: @jev,
      root: @root
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_recursive_search_of_filesystem_root_is_denied_before_jev
    result = Agent::Hooks.call(
      event('glob', 'pattern' => '**/*', 'path' => File::SEPARATOR),
      jev: @jev,
      root: @root
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_allowed_request_reaches_jev
    result = Agent::Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)

    assert_nil result
    assert_equal 1, @jev.calls
  end

  def test_jev_denial_blocks_an_allowed_request
    @jev = FakeJev.new(harmful: true)

    result = Agent::Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 1, @jev.calls
  end

  def test_session_id_is_injected_for_profile_tools
    event = event('mcp__agent-coord__set_profile', 'name' => 'marlow', 'session_id' => 'forged')
    result = Agent::Hooks.call(event, jev: @jev, root: @root)

    assert_equal 'session-1', result.dig('hookSpecificOutput', 'updatedInput', 'session_id')
    assert_equal 1, @jev.calls
  end

  def test_reassignment_is_denied_before_jev
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)

    result = Agent::Hooks.call(event('mcp__agent-coord__set_profile', 'name' => 'wren'), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_profile_registration_requires_hook_session_id
    result = Agent::Hooks.call(
      {
        'hook_event_name' => 'PreToolUse',
        'tool_name' => 'mcp__agent-coord__set_profile',
        'tool_input' => { 'name' => 'marlow' }
      },
      jev: @jev,
      root: @root
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_session_start_reports_id_without_calling_jev
    result = Agent::Hooks.call(
      { 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' },
      jev: @jev, root: @root
    )

    assert_includes result.dig('hookSpecificOutput', 'additionalContext'), 'session-1'
    assert_equal 0, @jev.calls
  end

  def test_unread_pings_ride_back_after_a_tool_call
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    Agent::Profile.ping('marlow', '@marlow check the pricer', from: 'wren', room: 'general', root: @root)

    result = Agent::Hooks.call(post_event, jev: @jev, root: @root)
    context = result.dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_includes context, 'wren in #general'
    assert_includes context, '@marlow check the pricer'
    assert_equal 0, @jev.calls
    assert_nil Agent::Hooks.call(post_event, jev: @jev, root: @root)
  end

  def test_post_tool_use_stays_quiet_without_pings
    assert_nil Agent::Hooks.call(post_event, jev: @jev, root: @root)

    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)

    assert_nil Agent::Hooks.call(post_event, jev: @jev, root: @root)
  end

  def test_post_tool_use_never_blocks_a_tool
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    pings = File.join(@root, 'agents', 'marlow', 'pings.jsonl')
    File.symlink(File.join(@root, 'agents', 'marlow', 'identity.md'), pings)

    assert_nil Agent::Hooks.call(post_event, jev: @jev, root: @root)
  end

  def test_pings_wait_for_a_tool_to_finish
    Agent::Profile.set_profile('marlow', session: 'session-1', root: @root)
    Agent::Profile.ping('marlow', 'look', from: 'wren', root: @root)

    assert_nil Agent::Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)
    assert_equal 1, Agent::Profile.read_pings('marlow', root: @root).length
  end

  def test_session_id_is_injected_for_chat_tools
    result = Agent::Hooks.call(event('mcp__agent-coord__send_message', 'text' => 'hi'), jev: @jev, root: @root)

    assert_equal 'session-1', result.dig('hookSpecificOutput', 'updatedInput', 'session_id')
  end

  private

  def event(tool_name, tool_input)
    {
      'hook_event_name' => 'PreToolUse',
      'session_id' => 'session-1',
      'tool_name' => tool_name,
      'tool_input' => tool_input
    }
  end

  def post_event
    {
      'hook_event_name' => 'PostToolUse',
      'session_id' => 'session-1',
      'tool_name' => 'exec',
      'tool_input' => { 'command' => 'git status' },
      'tool_response' => { 'success' => true, 'output' => '' }
    }
  end
end
