require 'fileutils'
require 'json'
require 'securerandom'

require_relative '../config'
require_relative '../profile_store'

# The mechanics every stream shares: jsonl IO, entry construction, read
# cursors, stream paths, and room naming. The sources (Inbox, Room) own their
# files and their verbs; nothing here knows what a DM or a room means.
module Bus
  DEFAULT_ROOM = 'general'
  CURSORS_FILE = 'cursors.json'

  class Error < StandardError
  end

  extend self

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
      'from' => from.to_s,
      'text' => text.to_s
    }
    entry['to'] = to.to_s if to
    entry['room'] = room.to_s if room
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
  def cursor(agent, key, root:)
    cursors(agent, root: root)[key.to_s].to_i
  end

  def advance_cursor(agent, key, count, root:)
    path = cursors_path(agent, root: root)
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
  def read_stream(agent, key, entries, limit: nil, root:)
    seen = cursor(agent, key, root: root)
    unread = seen.zero? && limit ? entries.last(limit) : entries.drop(seen)
    advance_cursor(agent, key, entries.length, root: root)
    unread
  end

  # The team room named by the workspace's config, so a bare room name means
  # the room this workspace actually talks in.
  def team_room(project:)
    name = Config.team_room(project: project).to_s.strip.sub(/\A#/, '').downcase
    ProfileStore.valid_name?(name) ? name : DEFAULT_ROOM
  end

  def normalize(name, project:)
    name = name.to_s.strip.sub(/\A#/, '').downcase
    name = team_room(project: project) if name.empty?
    raise Error, 'Invalid room name' unless ProfileStore.valid_name?(name)

    name
  end

  private

  def cursors(agent, root:)
    path = cursors_path(agent, root: root)
    File.exist?(path) ? parse_cursors(File.read(path)) : {}
  rescue SystemCallError => error
    raise Error, "Could not read the read cursor: #{error.class}"
  end

  def cursors_path(agent, root:)
    stream_path(ProfileStore.profile_dir(agent, root: root), CURSORS_FILE)
  end

  def parse_cursors(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
