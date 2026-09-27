# One room: the workspace-scoped side of the bus. A room holds the bus, so its
# methods take a profile and nothing else.
class Room
  def initialize(bus, name)
    @bus = bus
    @name = bus.normalize(name)
  end

  attr_reader :name

  def path
    @bus.stream_path(@bus.config.rooms_dir, "#{@name}.jsonl")
  end

  def messages
    @bus.read(path)
  end

  def unread(profile)
    messages.drop(@bus.cursor(profile, source))
  end

  def read(profile, limit: nil)
    @bus.read_stream(profile, source, messages, limit: limit)
  end

  def post(text, from:)
    entry = @bus.entry(from: from, text: text)
    @bus.append(path, entry)
    @bus.wake_source(source)
    entry
  end

  def wait(profile, timeout:)
    @bus.wait(profile, source, timeout: timeout, watch: [path])
  end

  private

  # The stream key a room's read cursor lives under.
  def source
    "room:#{@name}"
  end
end
