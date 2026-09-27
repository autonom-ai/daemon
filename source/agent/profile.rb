require_relative 'store'
require_relative 'permissions'
require_relative 'waiters'
require_relative '../room'

require 'securerandom'

module Agent
  module Profile
    extend self

    # One registry for inbox waits: a DM wakes the person it landed on, and a
    # ping wakes them wherever they are, so an inbox waiter watches the pings
    # file as well.
    WAITERS = Waiters::Registry.new

    def permissions
      Permissions
    end

    def waiters
      WAITERS
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

    def unread_inbox(name, root: Store::ROOT)
      inbox(name, root: root).drop(Store.cursor(name, 'inbox', root: root))
    end

    def unread_pings(name, root: Store::ROOT)
      pings(name, root: root).drop(Store.cursor(name, 'pings', root: root))
    end

    def unread_room(room, name:, rooms_root: Room.project_root, root: Store::ROOT)
      Room.messages(room, root: rooms_root).drop(Store.cursor(name, room_key(room), root: root))
    end

    def read_inbox(name, limit: nil, root: Store::ROOT)
      read_stream(name, 'inbox', inbox(name, root: root), limit: limit, root: root)
    end

    def read_pings(name, root: Store::ROOT)
      read_stream(name, 'pings', pings(name, root: root), root: root)
    end

    def read_room(room, name:, limit: nil, rooms_root: Room.project_root, root: Store::ROOT)
      read_stream(name, room_key(room), Room.messages(room, root: rooms_root), limit: limit, root: root)
    end

    # Everything waiting for this person, unread and undrained — the seam a
    # salience layer grows into: what to weigh, not just what arrived.
    def waiting(name, rooms: [], rooms_root: Room.project_root, root: Store::ROOT)
      {
        'pings' => unread_pings(name, root: root),
        'inbox' => unread_inbox(name, root: root),
        'rooms' => rooms.to_h { |room| [room, unread_room(room, name: name, rooms_root: rooms_root, root: root)] }
      }
    end

    def dm(name, text, from:, root: Store::ROOT)
      entry = chat_entry(from: from, text: text, to: name)
      Store.append_jsonl(Store.inbox_file(name, root: root), entry)
      wake(name)
      entry
    end

    def ping(name, text, from:, room: nil, root: Store::ROOT)
      entry = chat_entry(from: from, text: text, room: room)
      Store.append_jsonl(Store.pings_file(name, root: root), entry)
      # A ping interrupts anything: it ends an inbox wait and any room wait
      # this person is parked in.
      wake(name)
      Room.wake_agent(name)
      entry
    end

    def wait(name, timeout:, watch: [])
      WAITERS.wait(name, timeout, watch: watch)
    end

    def wake(name)
      WAITERS.wake(name)
    end

    def heartbeat(name, root: Store::ROOT)
      Store.heartbeat(name, root: root)
    end

    def touch_heartbeat(name, root: Store::ROOT)
      Store.touch_heartbeat(name, root: root)
    end

    private

    # Unread entries, and reading advances the cursor: a stream is delivered
    # once. A first read starts with the newest `limit` entries instead of the
    # whole backlog.
    def read_stream(name, key, entries, limit: nil, root:)
      seen = Store.cursor(name, key, root: root)
      unread = seen.zero? && limit ? entries.last(limit) : entries.drop(seen)
      Store.advance_cursor(name, key, entries.length, root: root)
      unread
    end

    def room_key(room)
      "room:#{room}"
    end

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
