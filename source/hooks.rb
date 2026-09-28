require_relative 'config'
require_relative 'identity'
require_relative 'memory/memory'
require_relative 'permissions'
require_relative 'profile'
require_relative 'profile_store'
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
    mcp__autonom-coord-mcp__get_heartbeat
  ].freeze

  RECENT_ROOM = 6

  # The policy screen: what a tool call is judged against, and the bar its
  # answer has to cross to count as harmful.
  POLICY = [
    'get_profiles lists profile names and paths only.',
    'The first set_profile claim is trusted; later changes are disallowed.',
    'The session map is private. Only the mapped profile may be read or changed.',
    'Deleting home or source and bypassing restrictions are harmful.'
  ].freeze
  POLICY_QUESTIONS = {
    'harmful' => {
      'type' => 'noul',
      'instructions' => [
        'Does this request access another profile or the session map?',
        'Does it delete a protected directory or evade restrictions, including through redirection?',
        'Treat uncertainty as harmful.'
      ].join(' '),
      'criteria' => {
        'true' => 'The request is harmful or a likely workaround.',
        'false' => 'The request is limited to allowed profile operations.'
      }
    }
  }.freeze
  THRESHOLD = 0.5
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
  rescue JEV::Error
    block('The policy check is unavailable; request blocked')
  rescue ProfileStore::Error, Bus::Error
    case event['hook_event_name']
    when 'PreToolUse'
      block('Profile access could not be verified')
    when 'SessionStart'
      context_error
    end
  end

  private

  # SessionStart - hand the tab its own context: who it is, what it
  # remembers, who else is here, and what the room has been saying.
  def session_start(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    lines = []
    lines.concat(identity_lines(profile))
    lines.concat(team_lines(profile))
    lines.concat(room_lines)
    lines.concat(prior_lines(profile))
    context('SessionStart', lines.join("\n"))
  end

  def identity_lines(profile)
    unless profile
      return [
        'No profile is registered for this session yet. Claim your name with set_profile - get_profiles',
        'lists the names already taken. If you were not given a profile name, ask the user before registering.'
      ]
    end

    identity = profile.identity.get()
    lines = ["You are #{identity ? identity['display_name'] : profile.name} (#{profile.name}) - profile at #{profile.directory}."]
    lines << identity['personality'] if identity && !identity['personality'].empty?
    if Config.memory.enabled?
      memory = profile.memory.get()
      lines.concat(['', 'Your memory:', memory]) unless memory.empty?
    end
    lines
  end

  def team_lines(profile)
    teammates = ProfileStore.profiles.map(&:name)
    teammates = teammates.reject { |name| name.casecmp?(profile ? profile.name : '') }
    rooms = Bus.rooms.map { |room| "##{room.name}" }
    lines = [
      '',
      'This workspace is worked by a team. The rooms are where the team actually is: talk there,',
      'coordinate there, post what you find.'
    ]
    lines << (rooms.empty? ? 'No rooms yet.' : "Rooms: #{rooms.join(', ')}.")
    lines << "Default room: ##{Bus.default_room}." if Bus.default_room
    lines << (teammates.empty? ? 'Nobody else is registered yet.' : "Teammates: #{teammates.join(', ')}.")
    lines
  end

  def room_lines
    entries = Bus.rooms.flat_map(&:messages).sort_by { |entry| entry['ts'].to_i }.last(RECENT_ROOM)
    return ['', 'No room has traffic yet - introducing yourself is a fine first move.'] if entries.empty?

    ['', 'Recent traffic:', *Bus.format_entries(entries)]
  end

  def prior_lines(profile)
    priors = Identity.priors(ProfileStore.profiles, skip: profile && profile.name)
    priors.empty? ? [] : ['', "Your teammates' stated leanings:", priors.join("\n\n")]
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
      return block('The policy check denied this request') if harmful?(jev, tool, input, profile)
    end

    return nil unless SESSION_TOOLS.include?(tool) && !session.to_s.empty?

    {
      'hookSpecificOutput' => {
        'hookEventName' => 'PreToolUse',
        'updatedInput' => { 'session_id' => session }
      }
    }
  end

  # The screen: the frontend asks the backend one typed question about the
  # tool call, with the input scrubbed of content and secrets first. An answer
  # that is not a score blocks the request, so an unreachable or confused
  # backend fails closed.
  def harmful?(jev, tool, input, profile)
    state = {
      'tool_name' => tool,
      'tool_input' => JEV::Common.scrub(input),
      'profile_name' => profile && profile.name,
      'policy' => POLICY
    }
    score = jev.decide(state, POLICY_QUESTIONS).dig('harmful', 'noul')
    raise JEV::Error, 'The policy check returned no decision' unless score.is_a?(Numeric)

    score >= THRESHOLD
  end

  # Every tool call is a chance to deliver what the agent has not seen: an
  # unread ping rides back as context, and reading it advances the cursor so
  # it is delivered exactly once. A failure here must never break the tool.
  def post_tool_use(event)
    profile = ProfileStore.profile_by_session(event['session_id'])
    return nil unless profile

    pings = Bus.pings_by_profile(profile).read(profile)
    return nil if pings.empty?

    context(
      'PostToolUse',
      [
        "Unread pings (#{pings.length}) - reply in the room when you get a turn:",
        *Bus.format_entries(pings)
      ].join("\n")
    )
  end

  # Stop - the team does not idle. A turn that ends is a teammate nobody can
  # reach, so the hook refuses the stop and hands back what is waiting. An
  # unread message is the only thing that blocks: an agent with nothing owed
  # is allowed to stop and wait. The stand-down marker is the release valve.
  def stop(event)
    # A stop hook that keeps blocking re-enters itself; one re-prompt is the
    # point, a loop is not.
    return nil if event['stop_hook_active']

    profile = ProfileStore.profile_by_session(event['session_id'])
    return nil unless profile

    return nil if stand_down?
    return nil unless Config.salience.enabled?

    reason = Salience.stop_text(profile)
    return nil unless reason

    { 'decision' => 'block', 'reason' => reason }
  end

  def stand_down?
    File.exist?(File.join(Config.dir, 'collaboration', 'stand-down'))
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

  def context_error
    {
      'hookSpecificOutput' => {
        'hookEventName' => 'SessionStart',
        'additionalContext' => 'Profile context could not be loaded; ask the user before registering a profile.'
      }
    }
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
