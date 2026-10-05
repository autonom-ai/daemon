module Coord
  module Tools
    SOURCES = %w[room dms pings].freeze
    WAIT_SOURCES = %w[room dms].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    DEFAULT_WAIT = 30
    MAX_WAIT = 60

    def tools
      session_schema = {
        'type' => 'string',
        'description' => 'Injected by the Devin session hook.'
      }
      [
        {
          'name' => 'get_profiles',
          'description' => 'List existing profile names and directories.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session_schema } }
        },
        {
          'name' => 'get_profile_status',
          'description' => 'Get a profile\'s status: its registered session and whether that session ' \
                           'is online. Omit `name` for the profile registered to this session.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'Profile name to check.' },
              'session_id' => session_schema
            }
          }
        },
        {
          'name' => 'set_profile',
          'description' => 'Register this session to one profile; creates it if needed.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The profile name to register.' },
              'session_id' => session_schema
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'post_message',
          'description' => 'Post a chat message. Pass `to` to DM one profile (the DM sits in their ' \
                           'dms and does not ping), or `room` for a room message. `room` is required ' \
                           'for room messages. `ping` names profiles to notify - each gets an unread ping, ' \
                           'delivered on their next tool call.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'text' => { 'type' => 'string', 'description' => 'The message text.' },
              'to' => { 'type' => 'string', 'description' => 'Profile name to DM; omit to post in a room.' },
              'room' => { 'type' => 'string', 'description' => 'Room to post in; ignored when `to` is set.' },
              'ping' => {
                'type' => 'array',
                'items' => { 'type' => 'string' },
                'description' => 'Profile names to ping.'
              },
              'session_id' => session_schema
            },
            'required' => ['text']
          }
        },
        {
          'name' => 'read_messages',
          'description' => 'Read chat messages. `source` picks `room`, `dms`, or `pings`; `room` is required ' \
                           'for room reads. Reading a stream clears what it returns.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => SOURCES, 'description' => 'Which stream to read.' },
              'room' => { 'type' => 'string', 'description' => 'Room to read when source is room.' },
              'limit' => {
                'type' => 'integer',
                'description' => "Maximum entries to return (default #{DEFAULT_LIMIT})."
              },
              'session_id' => session_schema
            }
          }
        },
        {
          'name' => 'wait_for_message',
          'description' => 'Block until something new arrives in `room` or `dms`; `room` is required for ' \
                           'room waits. Reading clears what it returns. A ping interrupts any wait and a DM ' \
                           'ends a dms wait; pings are not waitable.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'source' => { 'type' => 'string', 'enum' => WAIT_SOURCES, 'description' => 'Which stream to wait on.' },
              'room' => { 'type' => 'string', 'description' => 'Room to wait on when source is room.' },
              'timeout' => {
                'type' => 'integer',
                'description' => "Seconds to wait (default #{DEFAULT_WAIT}, max #{MAX_WAIT})."
              },
              'session_id' => session_schema
            }
          }
        },
        {
          'name' => 'list_rooms',
          'description' => 'List the workspace rooms: message count, unread count for this profile, and last activity.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'session_id' => session_schema } }
        },
        {
          'name' => 'create_room',
          'description' => 'Create a workspace room. Names are case-insensitive and stored lowercase.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room name to create.' },
              'session_id' => session_schema
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'delete_room',
          'description' => 'Delete a workspace room and its messages. Only the room\'s owner or admins may. ' \
                           'This cannot be undone.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room name to delete.' },
              'session_id' => session_schema
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'set_room_involved',
          'description' => 'Set which profiles may use a room. Pass `null` (or omit) for everyone in the clone; ' \
                           'a list makes it private, and two names is a DM. The room\'s owner and admins may set this.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'involved' => {
                'type' => ['array', 'null'],
                'items' => { 'type' => 'string' },
                'description' => 'Profile names allowed in the room, or null for everyone.'
              },
              'session_id' => session_schema
            },
            'required' => ['name']
          }
        },
        {
          'name' => 'add_room_admin',
          'description' => 'Make a profile an admin of a room. Only the room\'s original owner may change its admins.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'profile' => { 'type' => 'string', 'description' => 'The profile to add as an admin.' },
              'session_id' => session_schema
            },
            'required' => ['name', 'profile']
          }
        },
        {
          'name' => 'remove_room_admin',
          'description' => 'Remove a room admin. Only the room\'s original owner may change admins.',
          'inputSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string', 'description' => 'The room to change.' },
              'profile' => { 'type' => 'string', 'description' => 'The admin to remove.' },
              'session_id' => session_schema
            },
            'required' => ['name', 'profile']
          }
        }
      ]
    end
  end
end
