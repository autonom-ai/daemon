require_relative 'store'
require_relative 'permissions'

require 'securerandom'

module Agent
  module Profile
    extend self

    def permissions
      Permissions
    end

    def get_profiles(root: Store::ROOT)
      Store.get_profiles(root: root)
    end

    def get_profile(session, root: Store::ROOT)
      Store.get_profile(session, root: root)
    end

    def set_profile(name, session:, root: Store::ROOT)
      Store.set_profile(session, name, root: root)
    end

    # DMs and pings are profile-scoped: they live in the profile directory, not
    # the workspace, so they follow the person across workspaces.
    def inbox(name, root: Store::ROOT)
      Store.read_jsonl(Store.inbox_file(name, root: root))
    end

    def pings(name, root: Store::ROOT)
      Store.read_jsonl(Store.pings_file(name, root: root))
    end

    # Unread pings, and reading advances the cursor: a ping is delivered once,
    # either on the agent's next tool call or through read_messages.
    def read_pings(name, root: Store::ROOT)
      entries = pings(name, root: root)
      unread = entries.drop(Store.pings_cursor(name, root: root))
      Store.advance_pings_cursor(name, entries.length, root: root)
      unread
    end

    def dm(name, text, from:, root: Store::ROOT)
      entry = chat_entry(from: from, text: text, to: name)
      Store.append_jsonl(Store.inbox_file(name, root: root), entry)
      entry
    end

    def ping(name, text, from:, room: nil, root: Store::ROOT)
      entry = chat_entry(from: from, text: text, room: room)
      Store.append_jsonl(Store.pings_file(name, root: root), entry)
      entry
    end

    private

    def chat_entry(from:, text:, to: nil, room: nil)
      entry = {
        'id' => SecureRandom.uuid,
        'ts' => (Time.now.to_f * 1000).round,
        'from' => from.to_s,
        'text' => text.to_s
      }
      entry['to'] = to.to_s if to
      entry['room'] = room.to_s if room
      entry
    end
  end
end
