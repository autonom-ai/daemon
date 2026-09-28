# One stream on the bus: a named jsonl file with its own read cursor and wait.
# Rooms, dms, and pings are all inboxes; only the name and path differ.
class Inbox
  def initialize(name, path, watch: [])
    @name = name
    @path = path
    @watch = watch
  end

  attr_reader :name, :path

  def messages
    Bus.read(@path)
  end

  def unread(profile)
    messages.drop(Bus.cursor(profile, @name))
  end

  def read(profile, limit: nil)
    Bus.read_stream(profile, @name, messages, limit: limit)
  end

  def wait(profile, timeout:)
    Bus.wait(profile, @name, timeout: timeout, watch: [@path, *@watch])
  end
end
