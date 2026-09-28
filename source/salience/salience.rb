require_relative '../config'
require_relative '../identity'
require_relative '../memory/memory'
require_relative '../profile_store'
require_relative '../coord/bus'

# Salience is the arbiter of what an agent should be told about before it
# acts. Today the only signals are the ones it has not read yet, so the
# arbiter is deliberately deterministic: an unread ping, DM, or room line
# always outranks idling, and everything else is left to a later layer.
#
# Impulses are the shared vocabulary between what the bus notices and what
# the hooks say. A kind is one of KINDS; the rest is presentation.
module Salience
  MAX_CONTEXT = 2400
  RECENT_ROOM = 6

  KINDS = {
    'Respond' => {
      'channel' => 'Action',
      'action' => 'Answer the direct communication waiting for you.',
      'priority' => 5
    },
    'Coordinate' => {
      'channel' => 'Action',
      'action' => 'Join the most relevant open team thread.',
      'priority' => 4
    },
    'Continue' => {
      'channel' => 'Action',
      'action' => 'Continue the most valuable unfinished current work.',
      'priority' => 3
    },
    'Explore' => {
      'channel' => 'Action',
      'action' => 'Pursue the lead that best matches your interests.',
      'priority' => 2
    }
  }.freeze

  # An unread signal an agent has not acted on. The kind names the obligation;
  # the context is what it needs to read to meet it.
  Impulse = Struct.new(:kind, :context) do
    def initialize(kind, context)
      raise ArgumentError, "Unknown impulse: #{kind}" unless KINDS.key?(kind)

      super(kind, context.to_s[0, MAX_CONTEXT])
    end

    def action
      KINDS.fetch(kind)['action']
    end

    def channel
      KINDS.fetch(kind)['channel']
    end

    def priority
      KINDS.fetch(kind)['priority']
    end

    def required?
      kind == 'Respond'
    end
  end

  extend self

  def impulse(kind, context)
    Impulse.new(kind, context)
  end

  # Everything the agent has not read, as impulses. Reading drains a stream,
  # so a signal is offered until it is answered or explicitly dropped.
  def impulses(unread, last_message: nil, memory: nil)
    ret = []
    direct = unread['pings'].last(3) + unread['dms'].last(3)
    ret << impulse('Respond', Bus.format_entries(direct).join("\n")) unless direct.empty?

    rooms = unread['rooms'].flat_map do |room, entries|
      entries.last(3).map { |entry| entry.merge('room' => room) }
    end
    ret << impulse('Coordinate', Bus.format_entries(rooms.last(4)).join("\n")) unless rooms.empty?
    ret << impulse('Continue', last_message) unless last_message.to_s.strip.empty?
    ret << impulse('Explore', memory) unless memory.to_s.strip.empty?
    ret
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

  def stop_text(profile)
    unread = Bus.unread(profile)
    focus = focus(impulses(unread))
    return nil unless focus

    lines = [
      'Do not end the turn yet - this team does not idle.',
      '',
      "Waiting on you: #{focus.action}",
      clip(focus.context, 1000)
    ]
    lines.concat(unread_lines(unread))
    lines.concat(
      [
        '',
        'Answer what is owed first. Otherwise do real work and post what you find.',
        'Only when there is genuinely nothing to say or do, call wait_for_message on the room.'
      ]
    )
    lines.join("\n")
  end

  def briefing(profile)
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
