require_relative 'profile_store'
require_relative 'permissions'
require_relative 'coord/inbox'
require_relative 'coord/room'

module Profile
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
  def get_unread(name, rooms: [], rooms_root: Room.project_root, root: ProfileStore::ROOT)
    {
      'pings' => Inbox.unread_pings(name, root: root),
      'inbox' => Inbox.unread(name, root: root),
      'rooms' => rooms.to_h do |room|
        [
          room,
          unread_room(room, name: name, rooms_root: rooms_root, root: root)
        ]
      end
    }
  end

  def unread_room(room, name:, rooms_root: Room.project_root, root: ProfileStore::ROOT)
    Room.messages(room, root: rooms_root).drop(ProfileStore.cursor(name, room_key(room), root: root))
  end

  def read_room(room, name:, limit: nil, rooms_root: Room.project_root, root: ProfileStore::ROOT)
    ProfileStore.read_stream(name, room_key(room), Room.messages(room, root: rooms_root), limit: limit, root: root)
  end

  def heartbeat(name, root: ProfileStore::ROOT)
    ProfileStore.heartbeat(name, root: root)
  end

  def touch_heartbeat(name, root: ProfileStore::ROOT)
    ProfileStore.touch_heartbeat(name, root: root)
  end

  private

  def room_key(room)
    "room:#{room}"
  end
end
