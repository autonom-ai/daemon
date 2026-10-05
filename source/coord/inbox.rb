# One stream on the bus: a named jsonl file with its own read cursor and wait.
# Rooms, dms, and pings are all inboxes; only the name and path differ.
require_relative 'stream_store'

class Inbox
  def initialize(stream_name, file_path, watch_paths: [])
    @stream_name = stream_name
    @file_path = file_path
    @watch_paths = watch_paths
  end

  attr_reader :stream_name, :file_path

  def messages
    Bus::StreamStore.read(@file_path)
  end

  # Own posts are never unread: echo is not correspondence.
  def unread(profile)
    messages.drop(Bus::StreamStore.cursor(profile, @stream_name))
      .reject { |entry| entry['from'].to_s.casecmp?(profile.name) }
  end

  def read(profile, limit: nil)
    Bus::StreamStore.read_stream(profile, @stream_name, messages, limit: limit)
  end

  def wait(profile, timeout:)
    Bus.wait(profile, @stream_name, timeout: timeout, watch_paths: [@file_path, *@watch_paths])
  end
end
