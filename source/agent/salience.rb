module Agent
  # Text for signals an agent has not read yet.
  module Salience
    MAX_ENTRY = 400

    extend self

    def unread_lines(unread)
      lines = []
      pings = unread['pings']
      lines.concat(
        ['', "Unread pings (#{pings.length}) - reply when you get a turn:", *format_entries(pings)]
      ) unless pings.empty?
      inbox = unread['inbox']
      lines.concat(
        ['', "Unread direct messages (#{inbox.length}) - read_messages inbox:", *format_entries(inbox)]
      ) unless inbox.empty?
      unread['rooms'].each do |room, entries|
        lines.concat(
          ['', "New ##{room} traffic (#{entries.length}):", *format_entries(entries)]
        ) unless entries.empty?
      end
      lines << '' << 'Nothing new on the bus.' if lines.empty?
      lines
    end

    def stop_text(unread)
      [
        'Do not end the turn yet - this team does not idle.',
        *unread_lines(unread),
        '',
        'Anything the room is waiting on from you - a question, a ping, a reply owed - answer it first.',
        'Otherwise do real work and post what you find. Only when there is genuinely nothing to say or do,',
        'call wait_for_message on the room, then look again.'
      ].join("\n")
    end

    def format_entries(entries)
      entries.map do |entry|
        room = entry['room'] ? " in ##{entry['room']}" : ''
        "[#{clock(entry['ts'])}] #{entry['from']}#{room}: #{clip(entry['text'], MAX_ENTRY)}"
      end
    end

    private

    def clock(ts)
      Time.at(ts.to_i / 1000.0).strftime('%H:%M:%S')
    end

    def clip(text, max)
      text = text.to_s
      text.length <= max ? text : "#{text[0, max - 1]}…"
    end
  end
end
