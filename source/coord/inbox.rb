require_relative '../profile_store'
require_relative 'room'
require_relative 'waiters'

require 'securerandom'

# DMs and pings are the profile-scoped side of the bus: they live in the
# profile directory, not the workspace, so they follow the person across
# workspaces.
module Inbox
  extend self

  # One registry for inbox waits: a DM wakes the person it landed on, and a
  # ping wakes them wherever they are, so an inbox waiter watches the pings
  # file as well.
  WAITERS = Waiters::Registry.new

  def messages(name, root: ProfileStore::ROOT)
    ProfileStore.read_jsonl(ProfileStore.inbox_file(name, root: root))
  end

  def pings(name, root: ProfileStore::ROOT)
    ProfileStore.read_jsonl(ProfileStore.pings_file(name, root: root))
  end

  def unread(name, root: ProfileStore::ROOT)
    messages(name, root: root).drop(ProfileStore.cursor(name, 'inbox', root: root))
  end

  def unread_pings(name, root: ProfileStore::ROOT)
    pings(name, root: root).drop(ProfileStore.cursor(name, 'pings', root: root))
  end

  def read(name, limit: nil, root: ProfileStore::ROOT)
    ProfileStore.read_stream(name, 'inbox', messages(name, root: root), limit: limit, root: root)
  end

  def read_pings(name, root: ProfileStore::ROOT)
    ProfileStore.read_stream(name, 'pings', pings(name, root: root), root: root)
  end

  def dm(name, text, from:, root: ProfileStore::ROOT)
    entry = chat_entry(from: from, text: text, to: name)
    ProfileStore.append_jsonl(ProfileStore.inbox_file(name, root: root), entry)
    wake(name)
    entry
  end

  def ping(name, text, from:, room: nil, root: ProfileStore::ROOT)
    entry = chat_entry(from: from, text: text, room: room)
    ProfileStore.append_jsonl(ProfileStore.pings_file(name, root: root), entry)
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

  def inbox_path(name, root: ProfileStore::ROOT)
    ProfileStore.inbox_file(name, root: root)
  end

  def pings_path(name, root: ProfileStore::ROOT)
    ProfileStore.pings_file(name, root: root)
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
