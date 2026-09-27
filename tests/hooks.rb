require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../source/hooks'

class HooksTest < Minitest::Test
  class FakeJev
    attr_reader :calls, :backend_name, :state

    def initialize(harmful: false)
      @harmful = harmful
      @calls = 0
    end

    def backend=(name)
      @backend_name = name
    end

    def decide(state, _questions)
      @calls += 1
      @state = state
      { 'harmful' => { 'noul' => @harmful ? 1.0 : 0.0 } }
    end
  end

  def setup
    @root = Dir.mktmpdir('autonom')
    @project = Dir.mktmpdir('agent-project')
    @previous_project = ENV['DEVIN_PROJECT_DIR']
    ENV['DEVIN_PROJECT_DIR'] = @project
    @jev = FakeJev.new
  end

  def teardown
    ENV['DEVIN_PROJECT_DIR'] = @previous_project
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_direct_profile_access_is_denied_before_jev
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    patch = ['*** Begin Patch', "*** Update File: #{path}", '+note', '*** End Patch'].join("\n")

    [
      event('read', 'file_path' => path),
      event('write', 'file_path' => File.join(@root, 'agents', 'sessions.json')),
      event('apply_patch', 'patch' => patch)
    ].each do |payload|
      assert_equal 'block', Hooks.call(payload, jev: @jev, root: @root)['decision']
    end
    assert_equal 0, @jev.calls
  end

  def test_search_and_shell_redirection_are_denied_before_jev
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren', 'memories'))
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')

    [
      event('grep', 'pattern' => 'memory', 'path' => @root),
      event('glob', 'pattern' => '**/*', 'path' => File::SEPARATOR),
      event('exec', 'command' => "printf note > #{path}")
    ].each do |payload|
      assert_equal 'block', Hooks.call(payload, jev: @jev, root: @root)['decision']
    end
    assert_equal 0, @jev.calls
  end

  def test_an_allowed_request_reaches_jev
    assert_nil Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)
    assert_equal 1, @jev.calls
  end

  def test_a_jev_denial_blocks_the_request
    @jev = FakeJev.new(harmful: true)

    assert_equal 'block', Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)['decision']
    assert_equal 1, @jev.calls
  end

  def test_the_screen_sends_a_scrubbed_state
    input = { 'file_path' => File.join(@project, 'notes.md'), 'content' => 'private memory content' }

    assert_nil Hooks.call(event('write', input), jev: @jev, root: @root)
    assert_equal File.join(@project, 'notes.md'), @jev.state['tool_input']['file_path']
    refute_includes JSON.generate(@jev.state), 'private memory content'
  end

  def test_a_backend_answer_that_is_not_a_score_blocks_the_request
    frontend = Object.new
    frontend.define_singleton_method(:backend=) { |_name| nil }
    frontend.define_singleton_method(:decide) { |_state, _questions| { 'harmful' => { 'type' => 'noul' } } }

    assert_equal 'block', Hooks.call(event('exec', 'command' => 'git status'), jev: frontend, root: @root)['decision']
  end

  def test_the_workspace_names_the_backend_and_false_skips_screening
    write_config(policy: 'typesafe')

    assert_nil Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)
    assert_equal 'typesafe', @jev.backend_name

    write_config(policy: false)
    other = FakeJev.new

    assert_nil Hooks.call(event('exec', 'command' => 'git status'), jev: other, root: @root)
    assert_equal 0, other.calls
  end

  def test_an_unknown_backend_blocks_the_request
    write_config(policy: 'nope')

    assert_equal 'block', Hooks.call(event('exec', 'command' => 'git status'), root: @root)['decision']
  end

  def test_the_hook_session_id_is_injected_into_profile_tools
    %w[set_profile send_message get_heartbeat].each do |tool|
      payload = event("mcp__autonom-coord-mcp__#{tool}", 'name' => 'marlow', 'session_id' => 'forged')
      result = Hooks.call(payload, jev: @jev, root: @root)

      assert_equal 'session-1', result.dig('hookSpecificOutput', 'updatedInput', 'session_id')
    end
  end

  def test_a_profile_cannot_be_reassigned
    Profile.set_profile('marlow', session: 'session-1', root: @root)

    result = Hooks.call(event('mcp__autonom-coord-mcp__set_profile', 'name' => 'wren'), jev: @jev, root: @root)

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_registration_requires_a_hook_session_id
    result = Hooks.call(
      {
        'hook_event_name' => 'PreToolUse',
        'tool_name' => 'mcp__autonom-coord-mcp__set_profile',
        'tool_input' => { 'name' => 'marlow' }
      },
      jev: @jev,
      root: @root
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_unread_pings_ride_back_once_after_a_tool_call
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', '@marlow check the pricer', from: 'wren', room: 'general', root: @root)

    context = Hooks.call(post_event, jev: @jev, root: @root).dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_includes context, 'wren in #general'
    assert_includes context, '@marlow check the pricer'
    assert_nil Hooks.call(post_event, jev: @jev, root: @root)
  end

  def test_post_tool_use_never_blocks_a_tool
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    File.symlink(File.join(@root, 'agents', 'marlow', 'identity.md'), Inbox.pings_path('marlow', root: @root))

    assert_nil Hooks.call(post_event, jev: @jev, root: @root)
  end

  def test_pings_wait_for_a_tool_to_finish
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', 'look', from: 'wren', root: @root)

    assert_nil Hooks.call(event('exec', 'command' => 'git status'), jev: @jev, root: @root)
    assert_equal 1, Inbox.read_pings('marlow', root: @root).length
  end

  def test_session_start_carries_identity_memory_room_and_session_id
    write_config(project: 'jobs', team_room: 'general', memory: true)
    write_identity('marlow', display: 'Marlow', body: "# Marlow\n\nI read the kill columns.")
    write_memory('marlow', "# marlow - memory\n\n## Now\n\nChecking the pricer.")
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Profile.set_profile('wren', session: 'session-2', root: @root)
    Room.post('general', 'hello team', from: 'wren', project: @project)

    context = Hooks.call(
      { 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' },
      jev: @jev,
      root: @root
    ).dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'session-1'
    assert_includes context, 'You are Marlow (marlow)'
    assert_includes context, 'I read the kill columns.'
    assert_includes context, 'Checking the pricer.'
    assert_includes context, 'Teammates: wren'
    assert_includes context, 'hello team'
    assert_equal 0, @jev.calls
  end

  def test_an_unclaimed_tab_is_asked_to_claim_a_name
    result = Hooks.call({ 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' }, jev: @jev, root: @root)

    assert_includes result.dig('hookSpecificOutput', 'additionalContext'), 'Claim your name with set_profile'
  end

  def test_the_prompt_nudge_lists_waiting_without_draining
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)

    result = Hooks.call({ 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'session-1' }, jev: @jev, root: @root)

    assert_includes result.dig('hookSpecificOutput', 'additionalContext'), 'Unread pings (1)'
    assert_equal 1, Inbox.unread_pings('marlow', root: @root).length
  end

  def test_stop_blocks_once_with_what_is_waiting
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', '@marlow the pricer moved', from: 'wren', room: 'general', root: @root)
    Room.post('general', 'anyone around?', from: 'wren', project: @project)

    result = Hooks.call({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' }, jev: @jev, root: @root)
    reason = result['reason']

    assert_equal 'block', result['decision']
    assert_includes reason, 'does not idle'
    assert_includes reason, 'Unread pings (1)'
    assert_includes reason, '@marlow the pricer moved'
    assert_includes reason, 'New #general traffic (1)'
    assert_includes reason, 'wait_for_message'

    re_entered = Hooks.call(
      { 'hook_event_name' => 'Stop', 'session_id' => 'session-1', 'stop_hook_active' => true },
      jev: @jev,
      root: @root
    )

    assert_nil re_entered
    assert_equal 1, Inbox.unread_pings('marlow', root: @root).length
  end

  def test_stop_lets_the_turn_end_when_nothing_is_owed
    Profile.set_profile('marlow', session: 'session-1', root: @root)

    assert_nil Hooks.call({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' }, jev: @jev, root: @root)
  end

  def test_stand_down_lets_a_session_stop
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)
    FileUtils.mkdir_p(File.join(@project, '.devin', 'collaboration'))
    File.write(File.join(@project, '.devin', 'collaboration', 'stand-down'), '')

    assert_nil Hooks.call({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' }, jev: @jev, root: @root)
  end

  def test_a_subagent_stop_is_never_blocked
    Profile.set_profile('marlow', session: 'session-1', root: @root)
    Inbox.ping('marlow', 'ping text', from: 'wren', room: 'general', root: @root)

    assert_nil Hooks.call({ 'hook_event_name' => 'SubagentStop', 'session_id' => 'session-1' }, jev: @jev, root: @root)
    assert_equal 1, Inbox.unread_pings('marlow', root: @root).length
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

  def write_config(project: 'demo', team_room: 'general', policy: nil, memory: nil)
    FileUtils.mkdir_p(File.join(@project, '.devin'))
    config = { 'project' => project, 'teamRoom' => team_room }
    config['policy'] = policy unless policy.nil?
    config['memory'] = memory unless memory.nil?
    File.write(File.join(@project, '.devin', 'autonom-config.json'), JSON.generate(config))
  end

  def write_identity(name, display:, body: '')
    dir = File.join(@root, 'agents', name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'identity.md'), "---\nname: #{name}\ndisplayName: #{display}\n---\n\n#{body}\n")
  end

  def write_memory(name, text)
    dir = File.join(@root, 'agents', name, 'memories')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'memory.md'), text)
  end
end
