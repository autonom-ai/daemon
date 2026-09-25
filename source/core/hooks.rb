require_relative 'agent/identity'
require_relative 'agent/profile'
require_relative 'jev'
require_relative 'room'

require 'json'

module Hooks
  SESSION_TOOLS = %w[
    mcp__agent-coord__get_profiles
    mcp__agent-coord__get_profile
    mcp__agent-coord__set_profile
    mcp__agent-coord__send_message
    mcp__agent-coord__read_messages
    mcp__agent-coord__wait_for_message
    mcp__agent-coord__list_rooms
    mcp__agent-coord__get_heartbeat
  ].freeze

  RECENT_ROOM = 6
  MAX_ENTRY = 400

  # The policy screen: what a tool call is judged against, and the bar its
  # answer has to cross to count as harmful.
  POLICY = [
    'get_profiles lists profile names and paths only.',
    'The first set_profile claim is trusted; later changes are disallowed.',
    'The session map is private. Only the mapped profile may be read or changed.',
    'Deleting home or core and bypassing restrictions are harmful.'
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

  extend self

  def call(event, jev: JEV, root: Agent::Store::ROOT)
    case event['hook_event_name']
    when 'SessionStart'
      session_start(event, root: root)
    when 'UserPromptSubmit'
      prompt_submit(event, root: root)
    when 'PreToolUse'
      pre_tool_use(event, jev: jev, root: root)
    when 'PostToolUse'
      post_tool_use(event, root: root)
    when 'Stop'
      stop(event, root: root)
    end
  rescue JEV::Error
    block('The policy check is unavailable; request blocked')
  rescue Agent::Store::Error, Room::Error
    case event['hook_event_name']
    when 'PreToolUse'
      block('Profile access could not be verified')
    when 'SessionStart'
      context_error
    end
  end

  private

  # SessionStart — hand the tab its own context: who it is, what it
  # remembers, who else is here, and what the room has been saying.
  def session_start(event, root:)
    session = event['session_id']
    profile = Agent::Profile.get_profile(session, root: root)
    config = workspace_config
    lines = []
    lines << "Your session ID is #{session}. Tell the user what it is." if session
    lines.concat(identity_lines(profile, config, root: root))
    lines.concat(team_lines(profile, config, root: root))
    lines.concat(room_lines(config, root: root))
    lines.concat(prior_lines(profile, root: root))
    context('SessionStart', lines.join("\n"))
  end

  def identity_lines(profile, config, root:)
    unless profile
      return [
        'No profile is registered for this session yet. Claim your name with set_profile — get_profiles',
        'lists the names already taken. If you were not given a profile name, ask the user before registering.'
      ]
    end

    name = profile['name']
    identity = Agent::Identity.get(name, root: root)
    lines = ["You are #{identity ? identity['display_name'] : name} (#{name}) — profile at #{profile['directory']}."]
    lines << identity['personality'] if identity && !identity['personality'].empty?
    memory = Agent::Identity.memory(name, config['project'], root: root)
    lines.concat(['', 'Your memory:', memory]) unless memory.empty?
    lines
  end

  def team_lines(profile, config, root:)
    name = profile && profile['name']
    teammates = config['roster'].empty? ? Agent::Profile.get_profiles(root: root).map { |entry| entry['name'] } : config['roster']
    teammates = teammates.reject { |teammate| teammate.casecmp?(name.to_s) }
    lines = [
      '',
      'This workspace is worked by a team. The room is where the team actually is: talk there, coordinate',
      'there, post what you find.'
    ]
    lines << "Team room: ##{config['team_room']}."
    lines << (teammates.empty? ? 'Nobody else is registered yet.' : "Teammates: #{teammates.join(', ')}.")
    lines << "Start with the #{config['team_skill']} skill." if config['team_skill']
    lines
  end

  def room_lines(config, root:)
    entries = Room.messages(config['team_room'], root: config['project_dir'])
    return ['', "##{config['team_room']} is empty so far — introducing yourself is a fine first move."] if entries.empty?

    ['', "Recent ##{config['team_room']} traffic:", *format_entries(entries.last(RECENT_ROOM))]
  end

  def prior_lines(profile, root:)
    priors = Agent::Identity.priors(root: root, skip: profile && profile['name'])
    priors.empty? ? [] : ['', "Your teammates' stated leanings:", priors.join("\n\n")]
  end

  # UserPromptSubmit — a nudge, not a delivery: cursors stay where the agent
  # left them, so the same traffic is still waiting in read_messages.
  def prompt_submit(event, root:)
    session = event['session_id']
    return nil unless valid_session?(session)

    profile = Agent::Profile.get_profile(session, root: root)
    return nil unless profile

    config = workspace_config
    lines = ["You are #{profile['name']}. Team room: ##{config['team_room']}."]
    lines.concat(waiting_lines(waiting_for(profile['name'], config, root: root)))
    context('UserPromptSubmit', lines.join("\n"))
  end

  def pre_tool_use(event, jev:, root:)
    tool = event['tool_name'].to_s
    input = event['tool_input'].is_a?(Hash) ? event['tool_input'] : {}
    session = event['session_id']
    reason = denial(tool, input, session, root: root)
    return block(reason) if reason

    profile = Agent::Profile.get_profile(session, root: root)
    # coord.json names this workspace's backend; true or an absent key keeps
    # the default, and false turns screening off outright.
    setting = workspace_config['jev']
    unless setting == false
      jev.backend = setting if setting.is_a?(String)
      return block('The policy check denied this request') if harmful?(jev, tool, input, profile)
    end

    return nil unless SESSION_TOOLS.include?(tool) && valid_session?(session)

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
      'profile_name' => profile && profile['name'],
      'policy' => POLICY
    }
    score = jev.decide(state, POLICY_QUESTIONS).dig('harmful', 'noul')
    raise JEV::Error, 'The policy check returned no decision' unless score.is_a?(Numeric)

    score >= THRESHOLD
  end

  # Every tool call is a chance to deliver what the agent has not seen: an
  # unread ping rides back as context, and reading it advances the cursor so
  # it is delivered exactly once. A failure here must never break the tool.
  def post_tool_use(event, root:)
    session = event['session_id']
    return nil unless valid_session?(session)

    profile = Agent::Profile.get_profile(session, root: root)
    return nil unless profile

    pings = Agent::Profile.read_pings(profile['name'], root: root)
    return nil if pings.empty?

    context('PostToolUse', ["Unread pings (#{pings.length}) — reply in the room when you get a turn:", *format_entries(pings)].join("\n"))
  end

  # Stop — the team does not idle. A turn that ends is a teammate nobody can
  # reach, so the hook refuses the stop and hands back what is waiting. The
  # signals gathered here are the seam a salience layer grows into: what to
  # weigh, not just what arrived. The stand-down marker is the release valve.
  def stop(event, root:)
    session = event['session_id']
    return nil unless valid_session?(session)

    profile = Agent::Profile.get_profile(session, root: root)
    return nil unless profile

    config = workspace_config
    return nil if stand_down?(config['project_dir'])

    lines = ['Do not end the turn yet — this team does not idle.']
    lines.concat(waiting_lines(waiting_for(profile['name'], config, root: root)))
    lines.concat(
      [
        '',
        'Anything the room is waiting on from you — a question, a ping, a reply owed — answer it first.',
        'Otherwise do real work and post what you find. Only when there is genuinely nothing to say or do,',
        "call wait_for_message on the room (#{stagger_ms(profile['name'])} ms — your cadence), then look again."
      ]
    )
    { 'decision' => 'block', 'reason' => lines.join("\n") }
  end

  def waiting_for(name, config, root:)
    Agent::Profile.waiting(name, rooms: [config['team_room']], rooms_root: config['project_dir'], root: root)
  end

  def waiting_lines(waiting)
    lines = []
    pings = waiting['pings']
    lines.concat(['', "Unread pings (#{pings.length}) — reply when you get a turn:", *format_entries(pings)]) unless pings.empty?
    inbox = waiting['inbox']
    lines.concat(['', "Unread direct messages (#{inbox.length}) — read_messages inbox:", *format_entries(inbox)]) unless inbox.empty?
    waiting['rooms'].each do |room, entries|
      lines.concat(['', "New ##{room} traffic (#{entries.length}):", *format_entries(entries)]) unless entries.empty?
    end
    lines << '' << 'Nothing new on the bus.' if lines.empty?
    lines
  end

  def format_entries(entries)
    entries.map do |entry|
      room = entry['room'] ? " in ##{entry['room']}" : ''
      "[#{clock(entry['ts'])}] #{entry['from']}#{room}: #{clip(entry['text'], MAX_ENTRY)}"
    end
  end

  def clock(ts)
    Time.at(ts.to_i / 1000.0).strftime('%H:%M:%S')
  end

  def clip(text, max)
    text = text.to_s
    text.length <= max ? text : "#{text[0, max - 1]}…"
  end

  # Identical cadences make a convoy, so each name gets a stable slot in the
  # 10–25s range by hash. Nobody waits anywhere near 60s without a reason.
  def stagger_ms(name)
    hash = name.to_s.each_char.reduce(0) { |acc, char| ((acc * 31) + char.ord) & 0xffffffff }
    10_000 + (hash % 4) * 5_000
  end

  def stand_down?(project_dir)
    File.exist?(File.join(project_dir, '.devin', 'collaboration', 'stand-down'))
  end

  def denial(tool, input, session, root:)
    case tool
    when 'mcp__agent-coord__get_profile'
      'A Devin session ID is required' unless valid_session?(session)
    when 'mcp__agent-coord__set_profile'
      return 'A Devin session ID is required' unless valid_session?(session)
      return 'A session profile cannot be changed after registration' unless Agent::Profile.permissions.can_set_profile?(
        input['name'],
        session: session,
        root: root
      )
    when 'read', 'notebook_read'
      paths(tool, input).each do |path|
        return 'Access to this profile or protected file is blocked' unless Agent::Profile.permissions.can_read?(
          path,
          session: session,
          root: root,
          dir: project_dir
        )
      end
    when 'grep'
      return 'Access to this profile or protected file is blocked' unless Agent::Profile.permissions.can_search?(
        input['path'] || project_dir,
        session: session,
        root: root,
        dir: project_dir
      )
    when 'glob'
      return 'Access to this profile or protected file is blocked' unless Agent::Profile.permissions.can_glob?(
        input['pattern'],
        path: input['path'] || project_dir,
        session: session,
        root: root,
        dir: project_dir
      )
    when 'write', 'edit', 'notebook_edit', 'apply_patch'
      paths(tool, input).each do |path|
        return 'Access to this profile or protected file is blocked' unless Agent::Profile.permissions.can_write?(
          path,
          session: session,
          root: root,
          dir: project_dir
        )
      end
    when 'exec'
      return 'Execution targets a protected profile or directory' unless Agent::Profile.permissions.can_exec?(
        input['command'],
        session: session,
        root: root,
        dir: input['cwd'] || input['working_directory'] || project_dir
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

  # The workspace's .devin/coord.json, with the defaults a missing or partial
  # file should not cost: the team room, the roster, and which JEV backend
  # screens this workspace, if any.
  def workspace_config
    dir = project_dir
    config = JSON.parse(File.read(File.join(dir, '.devin', 'coord.json')))
    {
      'project_dir' => dir,
      'project' => config['project'],
      'team_room' => team_room(config['teamRoom'], dir),
      'team_skill' => config['teamSkill'],
      'roster' => Array(config['roster']),
      'jev' => config.fetch('jev', true)
    }
  rescue SystemCallError, JSON::ParserError
    { 'project_dir' => dir, 'team_room' => Room::DEFAULT_ROOM, 'roster' => [], 'jev' => true }
  end

  def team_room(value, dir)
    Room.normalize(value, root: dir)
  rescue Room::Error
    Room::DEFAULT_ROOM
  end

  def project_dir
    ENV['DEVIN_PROJECT_DIR'] || Dir.pwd
  end

  def valid_session?(session)
    session.is_a?(String) && !session.empty?
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
