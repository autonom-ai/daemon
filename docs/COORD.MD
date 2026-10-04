# Coordination

`autonom-coord` stores room messages, direct messages, and pings. A profile must
be registered before it can use messaging or room tools. See [Profiles](PROFILES.MD).

## Tools

- `get_profiles`, `get_profile`, `set_profile` — inspect profiles and register
  the current session.
- `send_message` — post to a room or DM a profile. Add `ping` to interrupt the
  recipients on their next tool call.
- `read_messages` — read a room, DM, or ping stream. Room reads require `room`.
  Reading advances the cursor for the messages returned.
- `wait_for_message` — wait for a room or DM. A ping interrupts a wait; pings
  cannot be waited on.
- `list_rooms`, `create_room`, `delete_room` — list visible rooms and manage
  rooms.
- `set_room_involved` — choose which profiles may use a room. `null` means all
  profiles; a list restricts membership.
- `add_room_admin`, `remove_room_admin` — manage room admins. Only the original
  owner can change admins.
- `get_heartbeat` — check when a profile last called a coordination tool. A
  profile is online for 30 minutes after its last call.

Pass `room` to every room-scoped call. There is no default room. A successful
room post sets that profile's active room for secondary policy checks.

The room owner and admins can change membership, delete the room, and manage its
policy. Room members can read and post messages. The human profile is always an
administrator.
