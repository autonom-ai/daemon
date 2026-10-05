require_relative 'identity'
require_relative 'profile_store'
require_relative 'coord/bus'

module Salience
  RECENT_ROOM = 6

  extend self

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

  def stop_text(profile)
    unread = Bus.unread(profile)
    lines = ['Do not end the turn yet - this team does not idle.']
    lines.concat(unread_lines(unread))
    lines.concat(
      [
        '',
        'Anything the team is waiting on from you - a question, ping, reply, or assigned task - comes first.',
        'Otherwise continue the current user task: inspect the next dependency, verify the work,',
        'or post a useful finding.',
        'Do not invent side quests, simulate motivation, or produce a status update instead of advancing the task.',
        '',
        'Before waiting, choose a relevant room, post there, and pass that room explicitly to coordination tools.'
      ]
    )
    lines.join("\n")
  end

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

  def identity_lines(profile)
    unless profile
      return [
        'No profile is registered for this session yet. Claim your name with set_profile - get_profiles',
        'lists the names already taken. The human profile is reserved; ask the user if no agent name was provided.'
      ]
    end

    identity = profile.identity.get()
    lines = ["You are #{identity ? identity['display_name'] : profile.name} (#{profile.name}) - " \
             "profile at #{profile.directory}."]
    lines << identity['personality'] if identity && !identity['personality'].empty?
    lines
  end

  def team_lines(profile, profiles, rooms)
    teammates = profiles.map(&:name).reject do |name|
      name.casecmp?(profile.name) || name.casecmp?(ProfileStore::HUMAN_NAME)
    end
    room_names = rooms.map { |room| "##{room.name}" }
    lines = [
      '',
      'This workspace is worked by a team. Use rooms to coordinate concrete work, ownership, findings, and decisions.',
      'Pass a room explicitly to every room-scoped coordination call; there is no configured or implicit room.',
      'State the task and ownership before editing. One writer per file; do not duplicate a teammate\'s assignment.',
      'For judgment changes, propose and converge before editing. Share verified findings and uncertainties promptly.',
      'Reading traffic does not require a reply. Respond when addressed or when you have a non-redundant contribution.'
    ]
    lines << (room_names.empty? ? 'No rooms yet.' : "Rooms: #{room_names.join(', ')}.")
    lines << (teammates.empty? ? 'Nobody else is registered yet.' : "Teammates: #{teammates.join(', ')}.")
    lines
  end

  def room_lines(rooms)
    entries = rooms.flat_map do |room|
      room.inbox.messages.map { |entry| entry.merge('room' => room.stream) }
    end.sort_by { |entry| entry['ts'].to_i }.last(RECENT_ROOM)
    return ['', 'No room has traffic yet - introducing yourself with your task is a fine first move.'] if entries.empty?

    ['', 'Recent traffic:', *Bus.format_entries(entries)]
  end

  def prior_lines(profile, profiles)
    priors = Identity.priors(profiles, skip_profile_name: profile.name)
    priors.empty? ? [] : ['', "Your teammates' stated leanings:", priors.join("\n\n")]
  end

  def append_entries(lines, label, entries)
    return if entries.empty?

    lines.concat(['', "#{label} (#{entries.length}):", *Bus.format_entries(entries)])
  end
end
