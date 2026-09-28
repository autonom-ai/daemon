require 'json'
require 'minitest/autorun'

require_relative 'support'
require_relative '../source/hooks'

class HooksTest < Minitest::Test
  include CoreTest

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

  def setup()
    setup_core()
    write_room('general')
    @jev = FakeJev.new
  end

  def teardown()
    teardown_core()
  end

  # The entrypoint must load in a clean process. The suite preloads profile_store,
  # so a require cycle between permissions and profile_store only shows up here.
  def test_the_hook_entrypoint_loads_in_a_clean_process()
    hooks = File.expand_path('../source/hooks.rb', __dir__)

    assert system('ruby', '-e', "require #{hooks.inspect}", out: File::NULL, err: File::NULL)
  end

  def test_direct_profile_access_is_denied_before_jev()
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')
    patch = ['*** Begin Patch', "*** Update File: #{path}", '+note', '*** End Patch'].join("\n")

    [
      event('read', 'file_path' => path),
      event('write', 'file_path' => File.join(@root, 'agents', 'sessions.json')),
      event('apply_patch', 'patch' => patch)
    ].each do |payload|
      assert_equal 'block', hook(payload)['decision']
    end
    assert_equal 0, @jev.calls
  end

  def test_search_and_shell_redirection_are_denied_before_jev()
    FileUtils.mkdir_p(File.join(@root, 'agents', 'wren', 'memories'))
    path = File.join(@root, 'agents', 'wren', 'memories', 'notes.md')

    [
      event('grep', 'pattern' => 'memory', 'path' => @root),
      event('glob', 'pattern' => '**/*', 'path' => File::SEPARATOR),
      event('exec', 'command' => "printf note > #{path}")
    ].each do |payload|
      assert_equal 'block', hook(payload)['decision']
    end
    assert_equal 0, @jev.calls
  end

  def test_an_allowed_request_reaches_jev()
    assert_nil hook(event('exec', 'command' => 'git status'))
    assert_equal 1, @jev.calls
  end

  def test_a_jev_denial_blocks_the_request()
    @jev = FakeJev.new(harmful: true)

    assert_equal 'block', hook(event('exec', 'command' => 'git status'))['decision']
    assert_equal 1, @jev.calls
  end

  def test_the_screen_sends_a_scrubbed_state()
    input = { 'file_path' => File.join(@project, 'notes.md'), 'content' => 'private memory content' }

    assert_nil hook(event('write', input))
    assert_equal File.join(@project, 'notes.md'), @jev.state['tool_input']['file_path']
    refute_includes JSON.generate(@jev.state), 'private memory content'
  end

  def test_a_backend_answer_that_is_not_a_score_blocks_the_request()
    frontend = Object.new
    frontend.define_singleton_method(:backend=) { |_name| nil }
    frontend.define_singleton_method(:decide) { |_state, _questions| { 'harmful' => { 'type' => 'noul' } } }

    assert_equal 'block', hook(event('exec', 'command' => 'git status'), jev: frontend)['decision']
  end

  def test_the_workspace_names_the_backend_and_false_skips_screening()
    write_config('policy' => 'typesafe')

    assert_nil hook(event('exec', 'command' => 'git status'))
    assert_equal 'typesafe', @jev.backend_name

    write_config('policy' => false)
    other = FakeJev.new

    assert_nil hook(event('exec', 'command' => 'git status'), jev: other)
    assert_equal 0, other.calls
  end

  def test_an_unknown_backend_blocks_the_request()
    write_config('policy' => 'nope')

    assert_equal 'block', Hooks.call(event('exec', 'command' => 'git status'))['decision']
  end

  def test_the_hook_session_id_is_injected_into_profile_tools()
    %w[set_profile send_message list_rooms create_room delete_room get_heartbeat].each do |tool|
      payload = event("mcp__autonom-coord-mcp__#{tool}", 'name' => 'marlow', 'session_id' => 'forged')
      updated = hook(payload).dig('hookSpecificOutput', 'updatedInput')

      assert_equal 'session-1', updated['session_id']
    end
  end

  def test_a_profile_cannot_be_reassigned()
    ProfileStore.register_profile('marlow', 'session-1')

    result = hook(event('mcp__autonom-coord-mcp__set_profile', 'name' => 'wren'))

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_registration_requires_a_hook_session_id()
    result = Hooks.call(
      {
        'hook_event_name' => 'PreToolUse',
        'tool_name' => 'mcp__autonom-coord-mcp__set_profile',
        'tool_input' => { 'name' => 'marlow' }
      },
      jev: @jev
    )

    assert_equal 'block', result['decision']
    assert_equal 0, @jev.calls
  end

  def test_unread_pings_ride_back_until_read()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    Bus.ping(marlow, '@marlow check the pricer', from: wren, room: room('general'))

    context = hook(post_event).dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_includes context, 'wren in #room:general'
    assert_includes context, '@marlow check the pricer'

    # The injection is a peek: ignoring it does not consume it, so it rides
    # back after every tool call until read_messages drains the mailbox.
    refute_nil hook(post_event)
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length

    Bus.pings_by_profile(marlow).read(marlow)

    assert_nil hook(post_event)
  end

  def test_unread_pings_gate_tool_calls_until_read()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    Bus.ping(marlow, 'look', from: ProfileStore.register_profile('wren', 'session-2'))

    blocked = hook(event('exec', 'command' => 'git status'))

    assert_equal 'block', blocked['decision']
    assert_includes blocked['reason'], 'pings'
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
    assert_equal 0, @jev.calls

    # Any other tool is gated too - a dms read does not drain pings.
    assert_equal 'block', hook(event('mcp__autonom-coord-mcp__read_messages', 'source' => 'dms'))['decision']

    # The read that drains the mailbox is never gated, and still gets its
    # session id injected.
    updated = hook(event('mcp__autonom-coord-mcp__read_messages', 'source' => 'pings'))
      .dig('hookSpecificOutput', 'updatedInput')

    assert_equal 'session-1', updated['session_id']

    Bus.pings_by_profile(marlow).read(marlow)

    assert_nil hook(event('exec', 'command' => 'git status'))

    # The pings read and the retried exec each screened once.
    assert_equal 2, @jev.calls
  end

  def test_the_gate_respects_the_salience_switch()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    Bus.ping(marlow, 'look', from: ProfileStore.register_profile('wren', 'session-2'))
    write_config('salience' => false)

    assert_nil hook(event('exec', 'command' => 'git status'))
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  def test_post_tool_use_never_blocks_a_tool()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    File.symlink(File.join(marlow.directory, 'identity.md'), Bus.pings_by_profile(marlow).path)

    assert_nil hook(post_event)
  end



  def test_session_start_carries_identity_memory_and_rooms()
    write_config('project' => 'jobs', 'memory' => true)
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    File.write(File.join(marlow.directory, 'identity.md'), "---\ndisplayName: Marlow\n---\n\nI read the kill columns.\n")
    FileUtils.mkdir_p(File.join(marlow.directory, 'memories'))
    File.write(File.join(marlow.directory, 'memories', 'memory.md'), "# marlow - memory\n\n## Now\n\nChecking the pricer.\n")
    Bus.post(room('general'), 'hello team', from: wren)

    context = hook({ 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' })
      .dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'You are Marlow (marlow)'
    assert_includes context, 'I read the kill columns.'
    assert_includes context, 'Checking the pricer.'
    assert_includes context, 'Rooms: #room:general'
    assert_includes context, 'Teammates: wren'
    assert_includes context, 'hello team'
    assert_equal 0, @jev.calls
  end

  def test_an_unclaimed_tab_is_asked_to_claim_a_name()
    context = hook({ 'hook_event_name' => 'SessionStart', 'session_id' => 'session-1' })
      .dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Claim your name with set_profile'
  end

  def test_the_prompt_nudge_lists_waiting_without_draining()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    Bus.ping(marlow, 'ping text', from: ProfileStore.register_profile('wren', 'session-2'), room: room('general'))

    context = hook({ 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'session-1' })
      .dig('hookSpecificOutput', 'additionalContext')

    assert_includes context, 'Unread pings (1)'
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  def test_stop_keeps_blocking_while_something_is_owed()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    wren = ProfileStore.register_profile('wren', 'session-2')
    Bus.ping(marlow, '@marlow the pricer moved', from: wren, room: room('general'))
    Bus.post(room('general'), 'anyone around?', from: wren)

    result = hook({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' })
    reason = result['reason']

    assert_equal 'block', result['decision']
    assert_includes reason, 'does not idle'
    assert_includes reason, 'Unread pings (1)'
    assert_includes reason, '@marlow the pricer moved'
    assert_includes reason, 'New #room:general traffic (1)'
    assert_includes reason, 'wait_for_message'

    # A re-entered stop is still judged on what is owed - the gate does not
    # yield just because it already blocked.
    re_entered = hook({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1', 'stop_hook_active' => true })

    assert_equal 'block', re_entered['decision']
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  def test_stop_lets_the_turn_end_when_nothing_is_owed()
    ProfileStore.register_profile('marlow', 'session-1')

    assert_nil hook({ 'hook_event_name' => 'Stop', 'session_id' => 'session-1' })
  end

  def test_a_subagent_stop_is_never_blocked()
    marlow = ProfileStore.register_profile('marlow', 'session-1')
    Bus.ping(marlow, 'ping text', from: ProfileStore.register_profile('wren', 'session-2'), room: room('general'))

    assert_nil hook({ 'hook_event_name' => 'SubagentStop', 'session_id' => 'session-1' })
    assert_equal 1, Bus.pings_by_profile(marlow).unread(marlow).length
  end

  private

  def hook(event, jev: @jev)
    Hooks.call(event, jev: jev)
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
