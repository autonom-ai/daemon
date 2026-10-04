require 'fileutils'
require 'json'

require_relative 'identity'
require_relative 'profile_store'
require_relative 'workspace'

class Profile
  HEARTBEAT_FILE = 'heartbeat.json'
  ROOM_FILE = 'room.json'

  def initialize(name, directory)
    @name = name
    @directory = directory
  end

  attr_reader :name, :directory

  def identity
    @identity ||= Identity.new(self)
  end

  def last_room
    path = room_path
    return nil unless File.file?(path)

    File.open(path, 'r') do |file|
      file.flock(File::LOCK_SH)
      parse_rooms(file.read)[Workspace.project_dir]
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the last room: #{error.class}"
  end

  def focus_room(name)
    raise ProfileStore::Error, 'Invalid room name' unless ProfileStore.valid_name?(name)

    path = room_path
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      rooms = parse_rooms(file.read)
      rooms[Workspace.project_dir] = name
      file.truncate(0)
      file.rewind
      file.write(JSON.generate(rooms))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
    name
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the last room: #{error.class}"
  end

  # Profile heartbeat is determined by last MCP call.
  def heartbeat
    path = heartbeat_path
    File.exist?(path) ? parse_heartbeat(File.read(path)) : 0
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the heartbeat: #{error.class}"
  end

  def touch_heartbeat()
    path = heartbeat_path
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      file.truncate(0)
      file.rewind
      file.write(JSON.generate('ts' => (Time.now.to_f * 1000).round))
      file.flush
    ensure
      file.flock(File::LOCK_UN)
    end
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not update the heartbeat: #{error.class}"
  end

  private

  def heartbeat_path
    path = File.join(@directory, HEARTBEAT_FILE)
    raise ProfileStore::Error, 'Heartbeat must not be a symlink' if File.symlink?(path)

    path
  end

  def room_path
    path = File.join(@directory, ROOM_FILE)
    raise ProfileStore::Error, 'Last room must not be a symlink' if File.symlink?(path)

    path
  end

  def parse_rooms(raw)
    ret = raw.strip.empty? ? {} : JSON.parse(raw)
    unless ret.is_a?(Hash) && ret.all? { |path, name| path.is_a?(String) && ProfileStore.valid_name?(name) }
      raise ProfileStore::Error, 'Last room state has an invalid format'
    end

    ret
  rescue JSON::ParserError
    raise ProfileStore::Error, 'Last room state contains invalid JSON'
  end

  def parse_heartbeat(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed['ts'].to_i : 0
  rescue JSON::ParserError
    0
  end
end
