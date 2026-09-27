require 'fileutils'
require 'json'
require 'securerandom'

require_relative '../config'
require_relative '../profile'
require_relative '../profile_store'
require_relative 'inbox'
require_relative 'room'

# The workspace's bus: stream mechanics plus the handles over it. It owns the
# workspace config and the profile store, so a room, an inbox, and a profile
# hold the bus rather than being handed a root on every call.
class Bus
  CURSORS_FILE = 'cursors.json'

  class Error < StandardError
  end

  def initialize(config:, store:)
    @config = config
    @store = store
  end

  attr_reader :config, :store

  def profiles
    @store.records.map { |record| profile_from(record) }
  end

  def profile(session)
    record = @store.session(session)
    record && profile_from(record)
  end

  def register(session, name)
    profile_from(@store.register(session, name))
  end

  def profile_named(name)
    record = @store.record(name)
    record && profile_from(record)
  end

  def room(name)
    Room.new(self, name)
  end

  def rooms
    (room_names | [team_room]).sort.map { |name| Room.new(self, name) }
  end

  def inbox(profile)
    Inbox.new(self, profile)
  end

  def team_room
    name = @config.team_room.to_s.strip.sub(/\A#/, '').downcase
    @store.valid_name?(name) ? name : Config::DEFAULT_TEAM_ROOM
  end

  def normalize(name)
    name = name.to_s.strip.sub(/\A#/, '').downcase
    name = team_room if name.empty?
    raise Error, 'Invalid room name' unless @store.valid_name?(name)

    name
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

  # How far a profile has read each stream: "inbox", "pings", and
  # "room:<name>" keys, each holding the entry count already delivered.
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

  def wait(profile, source, timeout:, watch: [])
    @store.wait(profile.name, source, timeout: timeout, watch: watch)
  end

  def wake(profile, source)
    @store.wake(profile.name, source)
  end

  def wake_agent(profile)
    @store.wake_agent(profile.name)
  end

  def wake_source(source)
    @store.wake_source(source)
  end

  private

  def profile_from(record)
    Profile.new(self, record.name, record.directory)
  end

  def room_names
    dir = @config.rooms_dir
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      entry.delete_suffix('.jsonl') if entry.end_with?('.jsonl')
    end.sort
  end

  def cursors(profile)
    path = cursors_path(profile)
    File.exist?(path) ? parse_cursors(File.read(path)) : {}
  rescue SystemCallError => error
    raise Error, "Could not read the read cursor: #{error.class}"
  end

  def cursors_path(profile)
    stream_path(@store.directory(profile.name), CURSORS_FILE)
  end

  def parse_cursors(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
