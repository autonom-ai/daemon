class Inbox
  SOURCE = 'inbox'
  INBOX_FILE = 'inbox.jsonl'
  PINGS_FILE = 'pings.jsonl'

  def initialize(profile)
    @profile = profile
  end

  def path
    Bus.stream_path(@profile.directory, INBOX_FILE)
  end

  def pings_path
    Bus.stream_path(@profile.directory, PINGS_FILE)
  end

  def messages
    Bus.read(path)
  end

  def pings
    Bus.read(pings_path)
  end

  def unread
    messages.drop(Bus.cursor(@profile, SOURCE))
  end

  def unread_pings
    pings.drop(Bus.cursor(@profile, 'pings'))
  end

  def read(limit: nil)
    Bus.read_stream(@profile, SOURCE, messages, limit: limit)
  end

  def read_pings()
    Bus.read_stream(@profile, 'pings', pings)
  end

  def dm(text, from:)
    entry = Bus.entry(from: from, text: text, to: @profile)
    Bus.append(path, entry)
    Bus.wake(@profile, SOURCE)
    entry
  end

  def ping(text, from:, room: nil)
    entry = Bus.entry(from: from, text: text, room: room)
    Bus.append(pings_path, entry)
    # A ping interrupts anything: it ends an inbox wait and any room wait
    # this person is parked in.
    Bus.wake_agent(@profile)
    entry
  end

  def wait(timeout:)
    Bus.wait(@profile, SOURCE, timeout: timeout, watch: [path, pings_path])
  end
end
