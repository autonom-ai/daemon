module autonom.events.event;

import autonom.agent;
import autonom.config;
import autonom.coord.access : caller;
import autonom.coord.stream : HECTONANOSECONDS_PER_MILLISECOND;
import autonom.server;
import autonom.storage;
import serverino;

import std.datetime : Clock, UTC;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.uuid : randomUUID;

public:

@endpoint @route!"/api/events"
void readEvents(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Profile profile = caller(request);
    JSONValue ret = JSONValue.emptyObject;
    ret["events"] = JSONValue.emptyArray;
    foreach (event; events.read(profile))
        ret["events"].array ~= event.toJSON();

    respond(output, ret);
}

enum MAX_EVENTS = 1000;
enum EVENTS_FILE = "events.json";

class EventStore
{
public:
    const string directory;

    this(Config configuration, ProfileStore store)
    {
        directory = buildPath(configuration.dataDir, "coord");
        if (exists(directory) && isSymlink(directory))
            throw new Exception("Coordination directory must not be a symlink");

        foreach (Profile profile; store.list())
            pending[profile.name] = load(profile.name);
    }

    Event[] unread(Profile profile)
    {
        Event[]* found = profile.name in pending;
        return found is null ? null : (*found).dup;
    }

    Event[] read(Profile profile)
    {
        Event[]* found = profile.name in pending;
        if (found is null || !found.length)
            return null;

        Event[] ret = *found;
        *found = null;
        save(profile.name);
        return ret;
    }

    void surface(Profile profile, Event event)
    {
        if (profile.name !in pending)
            pending[profile.name] = null;

        Event[]* found = profile.name in pending;
        foreach (existing; *found)
        {
            if (existing.id == event.id)
                return;
        }

        *found ~= event;
        if (found.length > MAX_EVENTS)
            *found = (*found)[$ - MAX_EVENTS .. $];

        save(profile.name);
    }

    void clear(Profile profile, EventType type, string room = null)
    {
        Event[]* found = profile.name in pending;
        if (found is null || !found.length)
            return;

        Event[] remaining;
        bool changed;
        foreach (event; *found)
        {
            if (event.type == type && (!room.length || event.room == room))
                changed = true;
            else
                remaining ~= event;
        }

        if (!changed)
            return;

        *found = remaining;
        save(profile.name);
    }

private:
    Event[][string] pending;

    string inboxDir(string profileName) const
        => buildPath(directory, "inboxes", profileName);

    string eventsPath(string profileName) const
        => buildPath(inboxDir(profileName), EVENTS_FILE);

    Event[] load(string profileName)
    {
        string path = eventsPath(profileName);
        if (!exists(path))
            return null;

        JSONValue data = readJSON(path, 4 * 1024 * 1024);
        if (data.type != JSONType.array)
            throw new Exception("Invalid pending events");

        Event[] ret;
        foreach (entry; data.array)
        {
            Event event;
            if (!Event.parse(entry, event))
                throw new Exception("Invalid pending event");

            ret ~= event;
        }

        return ret;
    }

    void save(string profileName)
    {
        JSONValue data = JSONValue.emptyArray;
        Event[]* found = profileName in pending;
        if (found !is null)
        {
            foreach (event; *found)
                data.array ~= event.toJSON();
        }

        mkdirRecurse(inboxDir(profileName));
        atomicWrite(eventsPath(profileName), data.toString());
    }
}

struct Event
{
    string id;
    EventType type;
    long timestamp;
    string from;
    string room;
    string text;
    string schedule;

    static Event create(
        EventType type,
        string id,
        string from,
        string text,
        string room = null,
        string schedule = null
    )
    {
        Event ret;
        ret.id = id.length ? id.idup : randomUUID().toString();
        ret.type = type;
        ret.timestamp = Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND;
        ret.from = from;
        ret.room = room;
        ret.text = text;
        ret.schedule = schedule;
        return ret;
    }

    JSONValue toJSON() const
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["id"] = JSONValue(id);
        ret["type"] = JSONValue(cast(string)type);
        ret["ts"] = JSONValue(timestamp);
        ret["from"] = from.length ? JSONValue(from) : JSONValue(null);
        ret["room"] = room.length ? JSONValue(room) : JSONValue(null);
        ret["text"] = text.length ? JSONValue(text) : JSONValue(null);
        ret["schedule"] = schedule.length ? JSONValue(schedule) : JSONValue(null);
        return ret;
    }

    static bool parse(JSONValue data, out Event event)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["id", "type", "ts"])
        {
            if (field !in data.object)
                return false;
        }

        if (data["id"].type != JSONType.string || data["type"].type != JSONType.string ||
            data["ts"].type != JSONType.integer)
            return false;

        EventType type;
        if (!parseEventType(data["type"].str, type))
            return false;

        event.id = data["id"].str.idup;
        event.type = type;
        event.timestamp = data["ts"].integer;
        if ("from" in data.object && data["from"].type == JSONType.string)
            event.from = data["from"].str.idup;
        if ("room" in data.object && data["room"].type == JSONType.string)
            event.room = data["room"].str.idup;
        if ("text" in data.object && data["text"].type == JSONType.string)
            event.text = data["text"].str.idup;
        if ("schedule" in data.object && data["schedule"].type == JSONType.string)
            event.schedule = data["schedule"].str.idup;

        return true;
    }
}

enum EventType : string
{
    Room = "room",
    DM = "dm",
    Ping = "ping",
    Clock = "clock"
}

bool parseEventType(string value, out EventType type)
{
    switch (value)
    {
    case "room":
        type = EventType.Room;
        return true;

    case "dm":
        type = EventType.DM;
        return true;

    case "ping":
        type = EventType.Ping;
        return true;

    case "clock":
        type = EventType.Clock;
        return true;

    default:
        return false;
    }
}
