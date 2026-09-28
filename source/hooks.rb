require_relative 'config'
require_relative 'profile_store'
require_relative 'permissions'
require_relative 'policy'
require_relative 'salience/salience'
require_relative 'jev'
require_relative 'coord/bus'

require 'json'

module Hooks
  SESSION_TOOLS = %w[
    mcp__autonom-coord-mcp__get_profiles
    mcp__autonom-coord-mcp__get_profile
    mcp__autonom-coord-mcp__set_profile
    mcp__autonom-coord-mcp__send_message
    mcp__autonom-coord-mcp__read_messages
    mcp__autonom-coord-mcp__wait_for_message
    mcp__autonom-coord-mcp__list_rooms
    mcp__autonom-coord-mcp__create_room
    mcp__autonom-coord-mcp__delete_room
    mcp__autonom-coord-mcp__get_heartbeat
  ].freeze

  DENIED = 'Access to this profile or protected file is blocked'

  extend self

  def call(event, jev: JEV)
    case event['hook_event_name']
    when 'SessionStart'
      session_start(event)
    when 'UserPromptSubmit'
      prompt_submit(event)
    when 'PreToolUse'
      pre_tool_use(event, jev: jev)
    when 'PostToolUse'
      post_tool_use(event)
    when 'Stop'
      stop(event)
    when 'SubagentStop'
      # Avoid subagents waiting forever.
      nil
    end
  rescue JEV::Error, Policy::Error
    block('The policy check is unavailable; request blocked')
  rescue ProfileStore::Error, Bus::Error
    case event['hook_event_name']
    when 'PreToolUse'
      block('Profile access could not be verified')
    when 'SessionStart'
      context('SessionStart', 'Profile context could not be loaded; ask the user before registering a profile.')
    end
  end

  private

  # SessionStart - hand the tab its own context: who it is, what it
  # remembers, who else is here, and what the room has been saying.
  def session_start(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    context('SessionStart', Salience.briefing(profile))
  end

  # UserPromptSubmit - a nudge, not a delivery: cursors stay where the agent
  # left them, so the same traffic is still waiting in read_messages.
  def prompt_submit(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    return nil unless profile

    lines = ["You are #{profile.name}."]
    lines.concat(Salience.unread_lines(Bus.unread(profile)))
    context('UserPromptSubmit', lines.join("\n"))
  end

  def pre_tool_use(event, jev:)
    tool = event['tool_name'].to_s
    input = event['tool_input'].is_a?(Hash) ? event['tool_input'] : {}
    session = event['session_id']
    profile = ProfileStore.profile_by_session(session)
    reason = denial(tool, input, session, profile)
    return block(reason) if reason

    policy = Config.policy
    if policy.enabled?
      jev.backend = policy.backend if policy.backend.is_a?(String)
      # TODO: a room's own policy.yml never reaches a plain tool call - it is
      # enforced only on room-scoped MCP calls (see Server#deny_room_policy),
      # because a call carries no room context. Enforcing it here needs a
      # focus_room tool so a session can declare its active room and that
      # room's policy can join this chain.
      denied, reason = Policy.decide([Policy.workspace], policy_request(tool, input, profile), jev: jev)
      return block(reason || 'The policy check denied this request') if denied
    end

    return nil unless SESSION_TOOLS.include?(tool) && !session.to_s.empty?

    {
      'hookSpecificOutput' => {
        'hookEventName' => 'PreToolUse',
        'updatedInput' => { 'session_id' => session.to_s }
      }
    }
  end

  def policy_request(tool, input, profile)
    { 'tool_name' => tool, 'tool_input' => input, 'profile_name' => profile && profile.name }
  end

  # Every tool call is a chance to deliver what the agent has not seen: an
  # unread ping rides back as context, and reading it advances the cursor so
  # it is delivered exactly once. A failure here must never break the tool.
  def post_tool_use(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    return nil unless profile

    pings = Bus.pings_by_profile(profile).read(profile)
    return nil if pings.empty?

    context('PostToolUse', Salience.ping_lines(pings).join("\n"))
  end

  # Stop - the team does not idle. A turn that ends is a teammate nobody can
  # reach, so the hook refuses the stop and hands back what is waiting. An
  # unread message is the only thing that blocks: an agent with nothing owed
  # is allowed to stop and wait.
  def stop(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    return nil unless profile

    return nil unless Config.salience.enabled?

    reason = Salience.stop_text(profile)
    return nil unless reason

    { 'decision' => 'block', 'reason' => reason }
  end

  def denial(tool, input, session, profile)
    actor = profile || Unclaimed.new()
    case tool
    when 'mcp__autonom-coord-mcp__get_profile'
      'A Devin session ID is required' if session.to_s.empty?
    when 'mcp__autonom-coord-mcp__set_profile'
      return 'A Devin session ID is required' if session.to_s.empty?

      name = input['name'].to_s
      return 'A valid profile name is required' unless ProfileStore.valid_name?(name)
      return 'A session profile cannot be changed after registration' if profile && !profile.name.casecmp?(name)
    when 'read', 'notebook_read'
      paths(tool, input).each do |path|
        return DENIED unless actor.can_read?(path)
      end
    when 'grep'
      return DENIED unless actor.can_search?(input['path'] || Config.project_dir)
    when 'glob'
      return DENIED unless actor.can_glob?(input['pattern'], path: input['path'] || Config.project_dir)
    when 'write', 'edit', 'notebook_edit', 'apply_patch'
      paths(tool, input).each do |path|
        return DENIED unless actor.can_write?(path)
      end
    when 'exec'
      return 'Execution targets a protected profile or directory' unless actor.can_exec?(
        input['command'],
        dir: input['cwd'] || input['working_directory']
      )
    end

    nil
  end

  def paths(tool, input)
    return patch_paths(input['patch']) if tool == 'apply_patch'

    [input['file_path'], input['notebook_path'], input['path']].compact
  end

  def patch_paths(patch)
    return [] unless patch.is_a?(String)

    patch.scan(/^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$/).flatten
  end

  def context(event_name, text)
    {
      'hookSpecificOutput' => {
        'hookEventName' => event_name,
        'additionalContext' => text
      }
    }
  end

  def block(reason)
    { 'decision' => 'block', 'reason' => reason }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ret = Hooks.call(JSON.parse(STDIN.read))
    puts JSON.generate(ret) if ret
  rescue JSON::ParserError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook payload was invalid')
  rescue StandardError
    puts JSON.generate('decision' => 'block', 'reason' => 'The hook could not verify this request')
  end
end
