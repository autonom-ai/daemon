require 'json'
require 'minitest/autorun'

require_relative 'support'
require_relative '../source/hooks'

class HooksTest < Minitest::Test
  include CoreTest

  class FakeDecision
    attr_reader :calls, :state

    def initialize(harmful: false)
      @harmful = harmful
      @calls = 0
    end

    def harmful?(state, _question)
      @calls += 1
      @state = state
      @harmful
    end
  end

  def setup()
    setup_core()
    write_room('general')
    @decision = FakeDecision.new
  end

  def teardown()
    teardown_core()
  end

  def test_the_hook_entrypoint_loads_in_a_clean_process()
    hooks = File.expand_path('../source/hooks.rb', __dir__)

    assert system('ruby', '-e', "require #{hooks.inspect}", out: File::NULL, err: File::NULL)
  end

  def test_direct_profile_access_is_denied_before_the_model()
    ProfileStore.register_profile('marlow', 'session-1')
    path = File.join(@root, 'agents', 'wren', 'notes.md')
    patch = ['*** Begin Patch', "*** Update File: #{path}", '+note', '*** End Patch'].join("\n")

    [
      event('read', 'file_path' => path),
      event('write', 'file_path' => File.join(@root, 'agents', 'sessions.json')),
      event('apply_patch', 'patch' => patch)
    ].each do |payload|
      assert_equal 'block', hook(payload)['decision']
    end
    assert_equal 0, @decision.calls
  end

  def test_an_allowed_request_reaches_the_model()
    ProfileStore.register_profile('marlow', 'session-1')

    assert_nil hook(event('exec', 'command' => 'git status'))
    assert_equal 1, @decision.calls
  end

  def test_a_model_denial_blocks_the_request()
    ProfileStore.register_profile('marlow', 'session-1')
    @decision = FakeDecision.new(harmful: true)

    assert_equal 'block', hook(event('exec', 'command' => 'git status'))['decision']
    assert_equal 1, @decision.calls
  end

  def test_the_screen_sends_a_scrubbed_state()
    ProfileStore.register_profile('marlow', 'session-1')
    input = { 'file_path' => File.join(@project, 'notes.md'), 'content' => 'private content' }

    assert_nil hook(event('write', input))
    assert_equal File.join(@project, 'notes.md'), @decision.state['tool_input']['file_path']
    refute_includes JSON.generate(@decision.state), 'private content'
  end

  def test_session_ids_are_injected_into_both_mcp_servers()
    ProfileStore.register_profile('marlow', 'session-1')
    tools = %w[
      mcp__autonom-coord__set_profile
      mcp__autonom-coord__send_message
      mcp__autonom-coord__set_room_involved
      mcp__autonom-policy__check_policy
    ]
    tools.each do |tool|
      updated = hook(event(tool, 'name' => 'marlow', 'session_id' => 'forged'))
        .dig('hookSpecificOutput', 'updatedInput')

      assert_equal 'session-1', updated['session_id']
    end
  end

  def test_a_profile_cannot_be_reassigned_or_claim_human()
    ProfileStore.register_profile('marlow', 'session-1')

    assert_equal 'block', hook(event('mcp__autonom-coord__set_profile', 'name' => 'wren'))['decision']
    assert_equal 'block', Hooks.call(
      event('mcp__autonom-coord__set_profile', 'name' => 'human').merge('session_id' => 'session-2'),
      decision: @decision
    )['decision']
    assert_equal 0, @decision.calls
  end

  def test_unread_pings_gate_tools_until_they_are_read()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    Bus.ping(marlow, 'look', from: wren)

    blocked = hook(event('exec', 'command' => 'git status'))

    assert_equal 'block', blocked['decision']
    assert_includes blocked['reason'], 'pings'
    assert_equal 0, @decision.calls

    updated = hook(event('mcp__autonom-coord__read_messages', 'source' => 'pings'))
      .dig('hookSpecificOutput', 'updatedInput')

    assert_equal 'session-1', updated['session_id']
    Bus.pings_by_profile(marlow).read(marlow)
    assert_nil hook(event('exec', 'command' => 'git status'))
  end

  def test_post_tool_use_surfaces_pings_without_draining_them()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    Bus.ping(marlow, '@marlow check this', from: wren, room: room('general'))

    context = hook(post_event).dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_includes context, '@marlow check this'
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  def test_session_start_carries_identity_team_and_rooms_without_memory()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    File.write(File.join(marlow.directory, 'identity.md'), "---\ndisplayName: Marlow\n---\n\nI read kill columns.\n")
    Bus.post(room('general'), 'hello team', from: wren)

    context = hook({ 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' })
      .dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'You are Marlow (marlow)'
    assert_includes context, 'I read kill columns.'
    assert_includes context, 'Rooms: #general'
    assert_includes context, 'Teammates: wren'
    assert_includes context, 'hello team'
    refute_includes context, 'Your memory'
  end

  def test_the_prompt_nudge_lists_waiting_without_draining()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    Bus.ping(marlow, 'ping text', from: wren, room: room('general'))

    context = hook({ 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'session-1' })
      .dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  def test_stop_enforces_the_current_task_without_drives()
    ProfileStore.register_profile('marlow', 'session-1')

    result = hook({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' })

    assert_equal 'block', result['decision']
    assert_includes result['reason'], 'continue the current user task'
    assert_includes result['reason'], 'Do not invent side quests'
    refute_includes result['reason'], 'drive'
  end

  def test_posting_in_a_room_selects_its_policy()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    File.write(
      room('general').policy_path,
      "rules:\n  - match: { tool: exec }\n    action: deny\n    reason: room policy\n"
    )

    assert_nil hook(event('exec', 'command' => 'git status'))
    Bus.post(room('general'), 'working here', from: marlow)

    assert_equal room('general').policy_path, marlow.policy
    blocked = hook(event('exec', 'command' => 'git status'))

    assert_equal 'block', blocked['decision']
    assert_equal 'room policy', blocked['reason']
  end

  def test_a_missing_primary_policy_blocks_tool_use()
    ProfileStore.register_profile('marlow', 'session-1')
    File.unlink(Workspace.policy_path)

    assert_equal 'block', hook(event('exec', 'command' => 'git status'))['decision']
    assert_equal 0, @decision.calls
  end

  def test_the_policy_check_injects_only_the_session()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    Bus.post(room('general'), 'working here', from: marlow)
    updated = hook(event('mcp__autonom-policy__check_policy', 'secondary' => '/forged/policy.yml'))
      .dig('hookSpecificOutput', 'updatedInput')

    assert_equal({ 'session_id' => 'session-1' }, updated)
  end

  private

  def hook(event, decision: @decision)
    Hooks.call(event, decision: decision)
  end

  def event(tool_name, tool_input)
    {
      'hook_event_name' => 'PreToolUse',
      'session_id' => 'session-1',
      'tool_name' => tool_name,
      'tool_input' => tool_input
    }
  end

  def post_event()
    {
      'hook_event_name' => 'PostToolUse',
      'session_id' => 'session-1',
      'tool_name' => 'exec',
      'tool_input' => { 'command' => 'git status' },
      'tool_response' => { 'success' => true, 'output' => '' }
    }
  end
end
