require 'fileutils'
require 'json'
require 'securerandom'

require_relative '../config'
require_relative '../profile_store'
require_relative 'inbox'
require_relative 'room'

module Bus
  CURSORS_FILE = 'cursors.json'
  DESCRIPTION_KEY = 'description'

  class Error < StandardError
  end

  extend self

  def rooms
    dir = Config.rooms_dir
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      entry.delete_suffix('.jsonl') if entry.end_with?('.jsonl')
    end.sort.map { |name| Room.new(name, description(room_path(name))) }
  end

  def inbox(profile)
    Inbox.new(profile)
  end

  def unread(profile)
    mailbox = inbox(profile)
    {
      'pings' => mailbox.unread_pings,
      'inbox' => mailbox.unread,
      'rooms' => rooms.to_h { |room| [room.name, room.unread(profile)] }
    }
  end

  def room_name(name)
    name = name.to_s.strip.sub(/\A#/, '').downcase
    name = default_room if name.empty?
    raise Error, 'Invalid room name' unless ProfileStore.valid_name?(name)

    name
  end

  def default_room
    name = Config.default_room.to_s.strip.sub(/\A#/, '').downcase
    ProfileStore.valid_name?(name) ? name : nil
  end

  def room_path(name)
    stream_path(Config.rooms_dir, "#{room_name(name)}.jsonl")
  end

  def read(path)
    return [] unless File.exist?(path)

    File.read(path).lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  rescue SystemCallError => error
    raise Error, "Could not read chat stream: #{error.class}"
  end

  def head(path)
    line = File.exist?(path) ? File.open(path) { |file| file.gets } : nil
    line ? JSON.parse(line) : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def append(path, entry)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
      file.write("#{JSON.generate(entry)}\n")
    end
  rescue SystemCallError => error
    raise Error, "Could not append to chat stream: #{error.class}"
  end

  def entry(from:, text:, to: nil, room: nil)
    entry = {
      'id' => SecureRandom.uuid,
      'ts' => (Time.now.to_f * 1000).round,
      'from' => from.name,
      'text' => text.to_s
    }
    entry['to'] = to.name if to
    entry['room'] = room.name if room
    entry
  end

  # A stream file must not be a symlink, or an append would land wherever the
  # link points.
  def stream_path(dir, file)
    raise Error, 'Stream directory must not be a symlink' if File.symlink?(dir)

    path = File.join(dir, file)
    raise Error, 'Stream file must not be a symlink' if File.symlink?(path)

    path
  end

  def cursor(profile, key)
    cursors(profile)[key.to_s].to_i
  end

  def advance_cursor(profile, key, count)
    path = cursors_path(profile)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      current = parse_cursors(file.read)
      next if current[key.to_s].to_i >= count

      current[key.to_s] = count
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(current))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise Error, "Could not update the read cursor: #{error.class}"
  end

  # Unread entries, and reading advances the cursor: a stream is delivered
  # once. A first read starts with the newest `limit` entries instead of the
  # whole backlog.
  def read_stream(profile, key, entries, limit: nil)
    seen = cursor(profile, key)
    unread = seen.zero? && limit ? entries.last(limit) : entries.drop(seen)
    advance_cursor(profile, key, entries.length)
    unread
  end

  private

  def description(path)
    head = head(path)
    head && head[DESCRIPTION_KEY]
  end

  def cursors(profile)
    path = cursors_path(profile)
    File.exist?(path) ? parse_cursors(File.read(path)) : {}
  rescue SystemCallError => error
    raise Error, "Could not read the read cursor: #{error.class}"
  end

  def cursors_path(profile)
    stream_path(ProfileStore.directory(profile.name), CURSORS_FILE)
  end

  def parse_cursors(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
