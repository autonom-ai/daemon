"""The advertised coordination tools and their wire schemas."""

SOURCES = ["room", "dms", "pings"]

TOOLS = [
    {
        "name": "get_profiles",
        "description": "List existing profiles and the sessions registered to them.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "get_profile_status",
        "description": "Report a profile's registered session. Omit name for your own profile.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Profile name to check."},
            },
        },
    },
    {
        "name": "set_profile",
        "description": "Register this session to one profile, creating it if needed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Profile name to register."},
            },
            "required": ["name"],
        },
    },
    {
        "name": "post_message",
        "description": "Post a room message, or DM one profile with to. Ping names profiles to "
        "notify: each gets an event, delivered on their next tool call or by waking them.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "The message text."},
                "to": {"type": "string", "description": "Profile name to DM; omit to post in a room."},
                "room": {"type": "string", "description": "Room to post in; ignored when to is set."},
                "ping": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Profile names to ping.",
                },
            },
            "required": ["text"],
        },
    },
    {
        "name": "read_messages",
        "description": "Read chat messages. source picks room, dms, or pings; room is required for "
        "room reads. Reading clears the events for what it returns.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source": {"type": "string", "enum": SOURCES, "description": "Which stream to read."},
                "room": {"type": "string", "description": "Room to read when source is room."},
                "limit": {"type": "integer", "description": "Maximum entries to return (default 50)."},
            },
            "required": ["source"],
        },
    },
    {
        "name": "read_events",
        "description": "Read and clear your pending events: pings, scheduled room or dm activity, "
        "and clock wakes. Use this to consume pending coordination reminders.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "schedule",
        "description": "Schedule a wake. type ping or dm matches every event or one from profile; "
        "room also needs a room name; clock takes at (ISO-8601 timestamp, once) or every (seconds, "
        "repeating). A scheduled wake resumes this session instead of starting a fresh one.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": ["ping", "dm", "room", "clock"]},
                "from": {"type": "string", "description": "Only wake for events from this profile."},
                "room": {"type": "string", "description": "Room to watch when type is room."},
                "at": {"type": "string", "description": "ISO-8601 wake time when type is clock."},
                "every": {"type": "integer", "description": "Seconds between wakes when type is clock."},
            },
            "required": ["type"],
        },
    },
    {
        "name": "list_schedules",
        "description": "List this profile's schedules.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "cancel_schedule",
        "description": "Cancel one of this profile's schedules by id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Schedule id to cancel."},
            },
            "required": ["id"],
        },
    },
    {
        "name": "list_rooms",
        "description": "List visible rooms with message counts, unread counts, and last activity.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "create_room",
        "description": "Create a room. Names are case-insensitive and stored lowercase.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room name to create."},
            },
            "required": ["name"],
        },
    },
    {
        "name": "delete_room",
        "description": "Delete a room and its messages. Only the room's owner or admins may; this "
        "cannot be undone.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room name to delete."},
            },
            "required": ["name"],
        },
    },
    {
        "name": "set_room_involved",
        "description": "Set which profiles may use a room. Pass null (or omit) for everyone; a list "
        "makes it private. The room's owner and admins may set this.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room to change."},
                "involved": {
                    "type": ["array", "null"],
                    "items": {"type": "string"},
                    "description": "Profile names allowed in the room, or null for everyone.",
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "add_room_admin",
        "description": "Make a profile an admin of a room. Only the room's original owner may change admins.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room to change."},
                "profile": {"type": "string", "description": "The profile to add as an admin."},
            },
            "required": ["name", "profile"],
        },
    },
    {
        "name": "remove_room_admin",
        "description": "Remove a room admin. Only the room's original owner may change admins.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room to change."},
                "profile": {"type": "string", "description": "The admin to remove."},
            },
            "required": ["name", "profile"],
        },
    },
]
