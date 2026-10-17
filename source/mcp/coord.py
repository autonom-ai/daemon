"""Coordination tool argument handling and direct daemon operations."""

import json
import urllib.parse

import daemon


def room(arguments):
    value = arguments.get("room")
    if not isinstance(value, str) or not value:
        raise daemon.ToolError("A room is required")

    return value


def required(arguments, name):
    value = arguments.get(name)
    if not isinstance(value, str) or not value:
        raise daemon.ToolError("A %s is required" % name)

    return value


def profile_of(caller):
    for profile in daemon.call("GET", "/api/profiles"):
        if profile.get("session") and profile["session"].get("id") == caller:
            return profile

    raise daemon.ToolError("No profile is registered for this session; register one first")


def dispatch(name, arguments):
    caller = daemon.session()
    if name == "get_profiles":
        return daemon.call("GET", "/api/profiles")
    if name == "get_profile_status":
        target = arguments.get("name")
        if target:
            return daemon.call("GET", "/api/profiles/" + urllib.parse.quote(target))

        return profile_of(caller)
    if name == "set_profile":
        target = required(arguments, "name")
        existing = {profile["name"] for profile in daemon.call("GET", "/api/profiles")}
        if target.lower() not in existing:
            daemon.call("POST", "/api/profiles", {"name": target})

        return daemon.call("POST", "/api/profiles/" + urllib.parse.quote(target) + "/session", {"id": caller})
    if name == "post_message":
        body = {"text": required(arguments, "text")}
        if isinstance(arguments.get("ping"), list):
            body["ping"] = arguments["ping"]

        if arguments.get("to"):
            body["to"] = arguments["to"]
            return daemon.call("POST", "/api/messages", body, {"session": caller})

        return daemon.call(
            "POST", "/api/rooms/" + urllib.parse.quote(room(arguments)) + "/messages", body, {"session": caller}
        )
    if name == "read_messages":
        query = {"session": caller, "limit": arguments.get("limit")}
        source = arguments.get("source")
        if source == "room":
            return daemon.call("GET", "/api/rooms/" + urllib.parse.quote(room(arguments)) + "/messages", None, query)
        if source in ("dms", "pings"):
            query["source"] = source
            return daemon.call("GET", "/api/messages", None, query)

        raise daemon.ToolError("Source must be room, dms, or pings")
    if name == "read_events":
        return daemon.call("GET", "/api/events", None, {"session": caller})
    if name == "schedule":
        body = {"type": required(arguments, "type")}
        for field in ("from", "room", "at", "every"):
            if arguments.get(field) is not None:
                body[field] = arguments[field]

        return daemon.call("POST", "/api/schedules", body, {"session": caller})
    if name == "list_schedules":
        return daemon.call("GET", "/api/schedules", None, {"session": caller})
    if name == "cancel_schedule":
        path = "/api/schedules/" + urllib.parse.quote(required(arguments, "id"))
        return daemon.call("DELETE", path, None, {"session": caller})
    if name == "list_rooms":
        return daemon.call("GET", "/api/rooms", None, {"session": caller})
    if name == "create_room":
        return daemon.call("POST", "/api/rooms", {"name": required(arguments, "name")}, {"session": caller})
    if name == "delete_room":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name"))
        return daemon.call("DELETE", path, None, {"session": caller})
    if name == "set_room_involved":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/membership"
        involved = arguments.get("involved")
        if involved is not None and not isinstance(involved, list):
            raise daemon.ToolError("involved must be a list of profile names or null")

        return daemon.call("POST", path, {"involved": involved}, {"session": caller})
    if name == "add_room_admin":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/admins"
        return daemon.call("POST", path, {"profile": required(arguments, "profile")}, {"session": caller})
    if name == "remove_room_admin":
        path = "/api/rooms/" + urllib.parse.quote(required(arguments, "name")) + "/admins"
        return daemon.call("DELETE", path, None, {"session": caller, "profile": required(arguments, "profile")})

    raise daemon.ToolError("Unknown profile tool")


def call_tool(name, arguments):
    if not isinstance(arguments, dict):
        return {"content": [{"type": "text", "text": "Tool arguments must be an object"}], "isError": True}

    try:
        token = daemon.SESSION_CONTEXT.set(daemon.session())
    except daemon.ToolError as failure:
        return {"content": [{"type": "text", "text": str(failure)}], "isError": True}

    try:
        result = dispatch(name, arguments)
        return {"content": [{"type": "text", "text": json.dumps(result)}], "isError": False}
    except daemon.ToolError as failure:
        return {"content": [{"type": "text", "text": str(failure)}], "isError": True}
    finally:
        daemon.SESSION_CONTEXT.reset(token)
