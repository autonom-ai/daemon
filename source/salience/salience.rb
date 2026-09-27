# Salience is the arbiter of what an agent should be told about before it
# acts. Today the only signals are the ones it has not read yet, so the
# arbiter is deliberately deterministic: an unread ping, DM, or room line
# always outranks idling, and everything else is left to a later layer.
#
# Impulses are the shared vocabulary between what the bus notices and what
# the hooks say. A kind is one of KINDS; the rest is presentation.
module Salience
  MAX_ENTRY = 400
  MAX_CONTEXT = 2400

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
    direct = unread['pings'].last(3) + unread['inbox'].last(3)
    ret << impulse('Respond', format_entries(direct).join("\n")) unless direct.empty?

    rooms = unread['rooms'].flat_map do |room, entries|
      entries.last(3).map { |entry| entry.merge('room' => room) }
    end
    ret << impulse('Coordinate', format_entries(rooms.last(4)).join("\n")) unless rooms.empty?
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
    append_entries(lines, 'Unread direct messages', unread['inbox'])
    unread['rooms'].each do |room, entries|
      append_entries(lines, "New ##{room} traffic", entries)
    end
    lines << '' << 'Nothing new on the bus.' if lines.empty?
    lines
  end

  def stop_text(profile)
    unread = profile.unread
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

  def format_entries(entries)
    entries.map do |entry|
      room = entry['room'] ? " in ##{entry['room']}" : ''
      "[#{clock(entry['ts'])}] #{entry['from']}#{room}: #{clip(entry['text'], MAX_ENTRY)}"
    end
  end

  private

  def append_entries(lines, label, entries)
    return if entries.empty?

    lines.concat(['', "#{label} (#{entries.length}):", *format_entries(entries)])
  end

  def clock(ts)
    Time.at(ts.to_i / 1000.0).strftime('%H:%M:%S')
  end

  def clip(text, max)
    text = text.to_s
    text.length <= max ? text : "#{text[0, max - 1]}…"
  end
end
