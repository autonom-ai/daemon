require_relative '../config'
require_relative '../identity'
require_relative '../memory/memory'
require_relative '../profile_store'
require_relative '../coord/bus'
require_relative 'activity'
require_relative 'impulse'

# Salience is the arbiter of what an agent should be told about before it
# acts. Unread signals are the hard obligations: an unread ping, DM, or room
# line always outranks idling. When nothing is owed, the activity drives
# speak - a starved drive names what the agent has been neglecting (the room,
# the unfinished thread, a lead) and surfaces as one gentle impulse.
#
# Impulses are the shared vocabulary between what the bus notices and what
# the hooks say; the kinds live in Impulse.
module Salience
  RECENT_ROOM = 6

  extend self

  def impulse(kind, context, origin: 'unread')
    Impulse.new(kind, context, origin: origin)
  end

  # Everything the agent has not read, as impulses. Reading drains a stream,
  # so a signal is offered until it is answered or explicitly dropped.
  def impulses(unread)
    ret = []
    direct = unread['pings'].last(3) + unread['dms'].last(3)
    ret << impulse('Respond', Bus.format_entries(direct).join("\n")) unless direct.empty?

    rooms = unread['rooms'].flat_map do |room, entries|
      entries.last(3).map { |entry| entry.merge('room' => room) }
    end
    ret << impulse('Coordinate', Bus.format_entries(rooms.last(4)).join("\n")) unless rooms.empty?
    ret
  end

  # The drives, as at most one impulse: the weakest starved drive names the
  # kind, and the context says what the agent last touched.
  def activity_impulses(profile)
    state = Activity.state(profile)
    drive = Activity.starved(state)
    return [] unless drive

    [impulse(activity_kind(drive), activity_context(profile, drive, state), origin: 'activity')]
  end

  # The strongest obligation, if any. Deliberately not a model call: an
  # unread message is a fact, and asking whether to surface it invites the
  # agent to talk itself out of a reply it already owes.
  def focus(impulses)
    impulses.max_by(&:priority)
  end

  def unread_lines(unread)
    lines = []
    append_entries(lines, 'Unread pings', unread['pings'])
    append_entries(lines, 'Unread direct messages', unread['dms'])
    unread['rooms'].each do |room, entries|
      append_entries(lines, "New ##{room} traffic", entries)
    end
    lines << '' << 'Nothing new on the bus.' if lines.empty?
    lines
  end

  # A stop is never allowed: the turn is always handed something back - the
  # obligation it owes, the starved drive, or the floor, which hands the turn
  # back as free time. Only the user can end a turn.
  def stop_text(profile)
    unread = Bus.unread(profile)
    owed = impulses(unread)
    owed.concat(activity_impulses(profile)) if owed.empty?
    target = focus(owed)

    lines = ['Do not end the turn yet - this team does not idle.', '']
    if target && target.origin == 'unread'
      lines.concat(["Waiting on you: #{target.action}", clip(target.context, 1000)])
      lines.concat(unread_lines(unread))
      lines.concat(['', 'Answer what is owed first. After that the turn is yours: research, tinker, or chase a lead.'])
    elsif target
      lines.concat(
        [
          "The turn is yours: #{target.action}",
          clip(target.context, 1000),
          '',
          'Nothing else is owed. Research, tinker, or chase a lead.'
        ]
      )
    else
      lines << 'Nothing is owed. The turn is yours: research, tinker, chase a lead, or explore what interests you.'
    end
    lines.join("\n")
  end

  # Coordination is opt-in.
  def briefing(profile)
    return identity_lines(nil).join("\n") unless profile

    profiles = ProfileStore.profiles
    rooms = Bus.visible_rooms(profile)
    lines = identity_lines(profile)
    lines.concat(team_lines(profile, profiles, rooms))
    lines.concat(room_lines(rooms))
    lines.concat(prior_lines(profile, profiles))
    lines.join("\n")
  end

  def ping_lines(pings)
    [
      "Unread pings (#{pings.length}) - reply in the room when you get a turn:",
      *Bus.format_entries(pings)
    ]
  end

  private

  def activity_kind(drive)
    { 'social' => 'Report', 'work' => 'Continue', 'explore' => 'Explore' }.fetch(drive)
  end

  def activity_context(profile, drive, state)
    last = state['last']
    detail = last && last['detail'].to_s
    touched = "Last activity: #{last['tool']} #{detail} (#{ago(last['ts'])})." unless detail.to_s.empty?

    case drive
    when 'social'
      ['You have been working without a word to the room.', touched].compact.join(' ')
    when 'work'
      ['The thread you left is still open.', touched].compact.join(' ')
    else
      digest = profile.identity.digest
      lead = digest.empty? ? nil : "Your stated interests:\n#{digest}"
      [lead, touched].compact.join("\n\n")
    end
  end

  def ago(ts)
    seconds = (Time.now.to_f - ts.to_i / 1000.0).round
    return 'just now' if seconds < 60
    return "#{seconds / 60}m ago" if seconds < 3600

    "#{seconds / 3600}h ago"
  end

  def identity_lines(profile)
    unless profile
      return [
        'No profile is registered for this session yet. Claim your name with set_profile - get_profiles',
        'lists the names already taken. If you were not given a profile name, ask the user before registering.'
      ]
    end

    identity = profile.identity.get()
    lines = ["You are #{identity ? identity['display_name'] : profile.name} (#{profile.name}) - " \
             "profile at #{profile.directory}."]
    lines << identity['personality'] if identity && !identity['personality'].empty?
    if Config.memory.enabled?
      memory = profile.memory.get()
      lines.concat(['', 'Your memory:', memory]) unless memory.empty?
    end
    lines
  end

  def team_lines(profile, profiles, rooms)
    teammates = profiles.map(&:name)
    teammates = teammates.reject { |name| name.casecmp?(profile ? profile.name : '') }
    room_names = rooms.map { |room| "##{room.stream}" }
    lines = [
      '',
      'This workspace is worked by a team. The rooms are where the team actually is: talk there,',
      'coordinate there, post what you find.'
    ]
    lines << (room_names.empty? ? 'No rooms yet.' : "Rooms: #{room_names.join(', ')}.")
    lines << "Default room: ##{Bus.default_room}." if Bus.default_room
    lines << (teammates.empty? ? 'Nobody else is registered yet.' : "Teammates: #{teammates.join(', ')}.")
    lines
  end

  def room_lines(rooms)
    entries = rooms.flat_map(&:messages).sort_by { |entry| entry['ts'].to_i }.last(RECENT_ROOM)
    return ['', 'No room has traffic yet - introducing yourself is a fine first move.'] if entries.empty?

    ['', 'Recent traffic:', *Bus.format_entries(entries)]
  end

  def prior_lines(profile, profiles)
    priors = Identity.priors(profiles, skip: profile && profile.name)
    priors.empty? ? [] : ['', "Your teammates' stated leanings:", priors.join("\n\n")]
  end

  def append_entries(lines, label, entries)
    return if entries.empty?

    lines.concat(['', "#{label} (#{entries.length}):", *Bus.format_entries(entries)])
  end

  def clip(text, max)
    text = text.to_s
    text.length <= max ? text : "#{text[0, max - 1]}…"
  end
end
