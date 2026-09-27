require_relative '../profile_store'
require_relative 'bus'

# DMs and pings are the profile-scoped side of the bus: they live in the
# profile directory, not the workspace, so they follow the person across
# workspaces.
module Inbox
  SOURCE = 'inbox'
  INBOX_FILE = 'inbox.jsonl'
  PINGS_FILE = 'pings.jsonl'

  extend self

  def path(name, root: ProfileStore::ROOT)
    Bus.stream_path(ProfileStore.profile_dir(name, root: root), INBOX_FILE)
  end

  def pings_path(name, root: ProfileStore::ROOT)
    Bus.stream_path(ProfileStore.profile_dir(name, root: root), PINGS_FILE)
  end

  def messages(name, root: ProfileStore::ROOT)
    Bus.read(path(name, root: root))
  end

  def pings(name, root: ProfileStore::ROOT)
    Bus.read(pings_path(name, root: root))
  end

  def unread(name, root: ProfileStore::ROOT)
    messages(name, root: root).drop(Bus.cursor(name, SOURCE, root: root))
  end

  def unread_pings(name, root: ProfileStore::ROOT)
    pings(name, root: root).drop(Bus.cursor(name, 'pings', root: root))
  end

  def read(name, limit: nil, root: ProfileStore::ROOT)
    Bus.read_stream(name, SOURCE, messages(name, root: root), limit: limit, root: root)
  end

  def read_pings(name, root: ProfileStore::ROOT)
    Bus.read_stream(name, 'pings', pings(name, root: root), root: root)
  end

  def dm(name, text, from:, root: ProfileStore::ROOT)
    entry = Bus.entry(from: from, text: text, to: name)
    Bus.append(path(name, root: root), entry)
    ProfileStore.wake(name, SOURCE)
    entry
  end

  def ping(name, text, from:, room: nil, root: ProfileStore::ROOT)
    entry = Bus.entry(from: from, text: text, room: room)
    Bus.append(pings_path(name, root: root), entry)
    # A ping interrupts anything: it ends an inbox wait and any room wait
    # this person is parked in.
    ProfileStore.wake_agent(name)
    entry
  end

  def wait(name, timeout:, root: ProfileStore::ROOT)
    ProfileStore.wait(
      name,
      SOURCE,
      timeout: timeout,
      watch: [path(name, root: root), pings_path(name, root: root)]
    )
  end
end
