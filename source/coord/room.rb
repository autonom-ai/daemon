class Room
  DESCRIPTION_KEY = 'description'

  def initialize(name, description)
    @name = name
    @description = description
  end

  attr_reader :name, :description

  def path
    Bus.room_path(@name)
  end

  def messages
    entries = Bus.read(path)
    entries.first&.key?(DESCRIPTION_KEY) ? entries.drop(1) : entries
  end

  def unread(profile)
    messages.drop(Bus.cursor(profile, source))
  end

  def read(profile, limit: nil)
    Bus.read_stream(profile, source, messages, limit: limit)
  end

  def post(text, from:)
    entry = Bus.entry(from: from, text: text)
    Bus.append(path, entry)
    ProfileStore.wake_source(source)
    entry
  end

  def wait(profile, timeout:)
    ProfileStore.wait(profile, source, timeout: timeout, watch: [path])
  end

  private

  def source
    "room:#{@name}"
  end
end
