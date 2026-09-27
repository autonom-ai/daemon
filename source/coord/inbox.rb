# One profile's inbox: the profile-scoped side of the bus. DMs and pings live
# in the profile directory, not the workspace, so they follow the person
# across workspaces. An inbox holds the bus and the profile, so its methods
# take nothing but what varies.
class Inbox
  SOURCE = 'inbox'
  INBOX_FILE = 'inbox.jsonl'
  PINGS_FILE = 'pings.jsonl'

  def initialize(bus, profile)
    @bus = bus
    @profile = profile
  end

  def path
    @bus.stream_path(@bus.store.directory(@profile.name), INBOX_FILE)
  end

  def pings_path
    @bus.stream_path(@bus.store.directory(@profile.name), PINGS_FILE)
  end

  def messages
    @bus.read(path)
  end

  def pings
    @bus.read(pings_path)
  end

  def unread
    messages.drop(@bus.cursor(@profile, SOURCE))
  end

  def unread_pings
    pings.drop(@bus.cursor(@profile, 'pings'))
  end

  def read(limit: nil)
    @bus.read_stream(@profile, SOURCE, messages, limit: limit)
  end

  def read_pings()
    @bus.read_stream(@profile, 'pings', pings)
  end

  def dm(text, from:)
    entry = @bus.entry(from: from, text: text, to: @profile)
    @bus.append(path, entry)
    @bus.wake(@profile, SOURCE)
    entry
  end

  def ping(text, from:, room: nil)
    entry = @bus.entry(from: from, text: text, room: room)
    @bus.append(pings_path, entry)
    # A ping interrupts anything: it ends an inbox wait and any room wait
    # this person is parked in.
    @bus.wake_agent(@profile)
    entry
  end

  def wait(timeout:)
    @bus.wait(@profile, SOURCE, timeout: timeout, watch: [path, pings_path])
  end
end
