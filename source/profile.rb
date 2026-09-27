require 'fileutils'
require 'json'

require_relative 'config'
require_relative 'permissions'
require_relative 'profile_store'
require_relative 'coord/bus'
require_relative 'coord/inbox'
require_relative 'coord/room'

# The profile's view of the bus: who a session is, whether that person is
# around, and everything waiting for them across the inbox and the rooms.
module Profile
  HEARTBEAT_FILE = 'heartbeat.json'

  extend self

  def permissions
    Permissions
  end

  def get_profiles(root: ProfileStore::ROOT)
    ProfileStore.get_profiles(root: root)
  end

  def get_profile(session, root: ProfileStore::ROOT)
    ProfileStore.get_profile(session, root: root)
  end

  def set_profile(name, session:, root: ProfileStore::ROOT)
    ProfileStore.set_profile(session, name, root: root)
  end

  # The profile's unread view: DMs and pings come from the profile-scoped
  # Inbox, room traffic from the workspace-scoped Room, and the cursor that
  # says what has been read is the profile's own.
  def get_unread(name, rooms: [], project: Config.project_dir, root: ProfileStore::ROOT)
    {
      'pings' => Inbox.unread_pings(name, root: root),
      'inbox' => Inbox.unread(name, root: root),
      'rooms' => rooms.to_h do |room|
        [
          room,
          unread_room(room, name: name, project: project, root: root)
        ]
      end
    }
  end

  def unread_room(room, name:, project: Config.project_dir, root: ProfileStore::ROOT)
    Room.unread(room, agent: name, project: project, root: root)
  end

  def read_room(room, name:, limit: nil, project: Config.project_dir, root: ProfileStore::ROOT)
    Room.read(room, agent: name, limit: limit, project: project, root: root)
  end

  # Profile heartbeat is determined by last MCP call.
  def heartbeat(name, root: ProfileStore::ROOT)
    path = heartbeat_path(name, root: root)
    File.exist?(path) ? parse_heartbeat(File.read(path)) : 0
  rescue SystemCallError => error
    raise ProfileStore::Error, "Could not read the heartbeat: #{error.class}"
  end

  def touch_heartbeat(name, root: ProfileStore::ROOT)
    path = heartbeat_path(name, root: root)
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

  def heartbeat_path(name, root:)
    Bus.stream_path(ProfileStore.profile_dir(name, root: root), HEARTBEAT_FILE)
  end

  def parse_heartbeat(raw)
    parsed = raw.strip.empty? ? {} : JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed['ts'].to_i : 0
  rescue JSON::ParserError
    0
  end
end
