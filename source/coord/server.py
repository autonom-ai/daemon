"""autonom-coord MCP server.

Speaks the Model Context Protocol over stdio and proxies tool calls to the
autonom daemon's HTTP API. The Devin session hook injects ``session_id`` into
every tool input, and the daemon resolves the calling profile from it. A tool
call starts the daemon when it is not already listening.
"""

import fcntl
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INFO = {"name": "autonom-coord", "version": "0.1.0"}
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2025-03-26"
DEFAULT_PORT = "8080"
TIMEOUT_SECONDS = 15
START_TIMEOUT_SECONDS = 20
START_POLL_SECONDS = 0.25

SESSION = {"type": "string", "description": "Injected by the Devin session hook."}

SOURCES = ["room", "dms", "pings"]

TOOLS = [
    {
        "name": "get_profiles",
        "description": "List existing profiles and the sessions registered to them.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
    {
        "name": "get_profile_status",
        "description": "Report a profile's registered session. Omit name for your own profile.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Profile name to check."},
                "session_id": SESSION,
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
                "session_id": SESSION,
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
                "session_id": SESSION,
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
                "session_id": SESSION,
            },
            "required": ["source"],
        },
    },
    {
        "name": "read_events",
        "description": "Read and clear your pending events: pings, scheduled room or dm activity, "
        "and clock wakes. Use this when a tool call is blocked by unread events.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
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
                "session_id": SESSION,
            },
            "required": ["type"],
        },
    },
    {
        "name": "list_schedules",
        "description": "List this profile's schedules.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
    {
        "name": "cancel_schedule",
        "description": "Cancel one of this profile's schedules by id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Schedule id to cancel."},
                "session_id": SESSION,
            },
            "required": ["id"],
        },
    },
    {
        "name": "list_rooms",
        "description": "List visible rooms with message counts, unread counts, and last activity.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
    {
        "name": "create_room",
        "description": "Create a room. Names are case-insensitive and stored lowercase.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The room name to create."},
                "session_id": SESSION,
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
                "session_id": SESSION,
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
                "session_id": SESSION,
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
                "session_id": SESSION,
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
                "session_id": SESSION,
            },
            "required": ["name", "profile"],
        },
    },
]


class ToolError(Exception):
    """A tool call the daemon refused, reported to the agent as a tool error."""


def port():
    return os.environ.get("AUTONOM_PORT", DEFAULT_PORT)


def url(path):
    return "http://127.0.0.1:" + port() + path


def root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def state_directory():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "autonom")


def log_path():
    return os.path.join(state_directory(), "daemon-" + port() + ".log")


def running():
    try:
        with urllib.request.urlopen(url("/api/health"), timeout=1) as response:
            return json.loads(response.read() or b"null").get("status") == "ok"
    except Exception:
        return False


def spawn():
    binary = os.path.join(root(), "bin", "autonom-daemon")
    if not os.path.exists(binary):
        raise ToolError("The autonom daemon is not built: %s is missing" % binary)

    os.makedirs(state_directory(), exist_ok=True)
    environment = dict(os.environ)
    environment["AUTONOM_PORT"] = port()
    with open(log_path(), "ab") as log:
        return subprocess.Popen(
            [binary],
            cwd=root(),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )


def ensure():
    if running():
        return True

    os.makedirs(state_directory(), exist_ok=True)
    with open(os.path.join(state_directory(), "daemon-" + port() + ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if running():
            return True

        process = spawn()
        deadline = time.time() + START_TIMEOUT_SECONDS
        while time.time() < deadline:
            if running():
                return True
            if process.poll() is not None:
                return running()

            time.sleep(START_POLL_SECONDS)

    return False


def call(method, path, body=None, query=None):
    target = url(path)
    if query:
        target += "?" + urllib.parse.urlencode(
            {name: value for name, value in query.items() if value is not None}
        )

    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        target, data=data, method=method, headers={"content-type": "application/json"}
    )
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                return json.loads(response.read() or b"null")
        except urllib.error.HTTPError as failure:
            try:
                message = json.loads(failure.read()).get("error")
            except ValueError:
                message = None

            raise ToolError(message or "The daemon returned HTTP %d" % failure.code) from failure
        except OSError as failure:
            if attempt == 0 and ensure():
                continue

            raise ToolError(
                "The autonom daemon is unreachable: %s (log: %s)" % (failure, log_path())
            ) from failure


def session(arguments):
    value = arguments.get("session_id")
    if not isinstance(value, str) or not value:
        raise ToolError("No session ID; the autonom hooks are not installed for this session")

    return value


def room(arguments):
    value = arguments.get("room")
    if not isinstance(value, str) or not value:
        raise ToolError("A room is required")

    return value


def required(arguments, name):
    value = arguments.get(name)
    if not isinstance(value, str) or not value:
        raise ToolError("A %s is required" % name)

    return value


def profile_of(caller):
    for profile in call("GET", "/api/profiles"):
        if profile.get("session") and profile["session"].get("id") == caller:
            return profile

    raise ToolError("No profile is registered for this session; register one first")


def dispatch(name, arguments):
    caller = session(arguments)
    if name == "get_profiles":
        return call("GET", "/api/profiles")
    if name == "get_profile_status":
        target = arguments.get("name")
        if target:
            return call("GET", "/api/profiles/" + urllib.parse.quote(target))

        return profile_of(caller)
    if name == "set_profile":
        target = required(arguments, "name")
        existing = {profile["name"] for profile in call("GET", "/api/profiles")}
        if target.lower() not in existing:
            call("POST", "/api/profiles", {"name": target})

        return call("POST", "/api/profiles/" + urllib.parse.quote(target) + "/session", {"id": caller})
    if name == "post_message":
        body = {"text": required(arguments, "text")}
        if isinstance(arguments.get("ping"), list):
            body["ping"] = arguments["ping"]

        if arguments.get("to"):
            body["to"] = arguments["to"]
            return call("POST", "/api/messages", body, {"session": caller})

        return call(
            "POST", "/api/rooms/" + urllib.parse.quote(room(arguments)) + "/messages", body, {"session": caller}
        )
    if name == "read_messages":
        query = {"session": caller, "limit": arguments.get("limit")}
        source = arguments.get("source")
        if source == "room":
            return call("GET", "/api/rooms/" + urllib.parse.quote(room(arguments)) + "/messages", None, query)
        if source in ("dms", "pings"):
            query["source"] = source
            return call("GET", "/api/messages", None, query)

        raise ToolError("Source must be room, dms, or pings")
    if name == "read_events":
        return call("GET", "/api/events", None, {"session": caller})
    if name == "schedule":
        body = {"type": required(arguments, "type")}
        for field in ("from", "room", "at", "every"):
            if arguments.get(field) is not None:
                body[field] = arguments[field]

        return call("POST", "/api/schedules", body, {"session": caller})
    if name == "list_schedules":
        return call("GET", "/api/schedules", None, {"session": caller})
    if name == "cancel_schedule":
        path = "/api/schedules/" + urllib.parse.quote(required(arguments, "id"))
        return call("DELETE", path, None, {"session": caller})
    if name == "list_rooms":
        return call("GET", "/api/rooms", None, {"session": caller})
    if name == "create_room":
        return call("POST", "/api/rooms", {"name": required(arguments, "name")}, {"session": caller})
    if name == "delete_room":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name"))
        return call("DELETE", path, None, {"session": caller})
    if name == "set_room_involved":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/membership"
        involved = arguments.get("involved")
        if involved is not None and not isinstance(involved, list):
            raise ToolError("involved must be a list of profile names or null")

        return call("POST", path, {"involved": involved}, {"session": caller})
    if name == "add_room_admin":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/admins"
        return call("POST", path, {"profile": required(arguments, "profile")}, {"session": caller})
    if name == "remove_room_admin":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/admins"
        return call("DELETE", path, None, {"session": caller, "profile": required(arguments, "profile")})

    raise ToolError("Unknown profile tool")


def call_tool(name, arguments):
    try:
        result = dispatch(name, arguments)
    except ToolError as failure:
        return {"content": [{"type": "text", "text": str(failure)}], "isError": True}

    return {"content": [{"type": "text", "text": json.dumps(result)}], "isError": False}


def error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def success(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def handle(request):
    if not isinstance(request, dict):
        return error(None, -32600, "Invalid request")

    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") if isinstance(request.get("params"), dict) else {}
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if not isinstance(method, str):
        return error(request_id, -32600, "Invalid request")

    if method == "initialize":
        protocol = params.get("protocolVersion")
        if protocol not in PROTOCOLS:
            protocol = DEFAULT_PROTOCOL

        return success(
            request_id,
            {
                "protocolVersion": protocol,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": INFO,
            },
        )
    if method == "ping":
        return success(request_id, {})
    if method == "tools/list":
        return success(request_id, {"tools": TOOLS})
    if method == "tools/call":
        return success(
            request_id,
            call_tool(params.get("name") or "", params.get("arguments") or {}),
        )

    return error(request_id, -32601, "Method not found")


def run():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except ValueError:
            request = None

        try:
            response = handle(request) if request is not None else error(None, -32700, "Parse error")
        except Exception as failure:
            request_id = request.get("id") if isinstance(request, dict) else None
            response = error(request_id, -32603, "Internal error: %s" % failure)

        if response is None:
            continue

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    run()
