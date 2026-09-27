require 'fileutils'
require 'json'

require_relative 'identity'
require_relative 'memory/memory'
require_relative 'permissions'
require_relative 'profile_store'

# A profile as the bus sees it: who it is, where it lives, and everything
# waiting for them across the inbox and the rooms. Profile-dependent things
# hang off the profile itself.
class Profile
  include Permissions

  HEARTBEAT_FILE = 'heartbeat.json'

  def initialize(bus, name, directory)
    @bus = bus
    @name = name
    @directory = directory
  end

  attr_reader :bus, :name, :directory

  def inbox
    @bus.inbox(self)
  end

  def identity
    @identity ||= Identity.new(self)
  end

  def memory
    @memory ||= Memory.new(self)
  end

  # Everything waiting for this profile: unread pings, unread DMs, and the
  # unread lines of the team room, keyed by room name.
  def unread
    room = @bus.room(@bus.team_room)
    {
      'pings' => inbox.unread_pings,
      'inbox' => inbox.unread,
      'rooms' => { room.name => room.unread(self) }
    }
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
    @bus.stream_path(@bus.store.directory(@name), HEARTBEAT_FILE)
  end

  def parse_heartbeat(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed['ts'].to_i : 0
  rescue JSON::ParserError
    0
  end
end
