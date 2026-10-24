module daemon.events.event;

import daemon.agent;
import daemon.config;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.storage;

import std.datetime : Clock, UTC;
import std.algorithm : canFind;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.stdio : stderr;
import std.uuid : randomUUID;

enum maxEvents = 1000;
enum eventsFile = "events.json";

class EventStore
{
private:
    Event[][string] pending;
    string[][string] receipts;

public:
    const string directory;

    this(Config configuration, ProfileStore store)
    {
        directory = buildPath(configuration.dataDir, "coord");
        if (exists(directory) && isSymlink(directory))
            throw new Exception("Coordination directory must not be a symlink");

        foreach (Profile profile; store.list())
        {
            pending[profile.name] = load(profile.name);
            string path = buildPath(inboxDir(profile.name), "receipts.json");
            if (exists(path))
            {
                try
                {
                    foreach (entry; readJSON(path, 256 * 1024).array)
                        receipts[profile.name] ~= entry.str.idup;
                    if (receipts[profile.name].length > maxEvents)
                        receipts[profile.name] = receipts[profile.name][$-maxEvents..$];
                }
                catch (Exception)
                {
                    rename(path, path~".corrupt-"~randomUUID().toString());
                    receipts.remove(profile.name);
                    stderr.writeln("autonom: preserved corrupt event receipts for ", profile.name);
                }
            }
        }
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

    /// Acknowledge only matching IDs in this profile's inbox; repeated or foreign IDs are harmless.
    string[] acknowledge(Profile profile, string[] ids)
    {
        bool[string] observed;
        foreach (id; ids)
            observed[id] = true;

        string[] ret;
        Event[] remaining;
        foreach (event; unread(profile))
        {
            if (event.id in observed)
                ret ~= event.id;
            else
                remaining ~= event;
        }
        if (!ret.length)
            return ret;

        bool committed;
        scope(exit)
        {
            if (committed)
                pending[profile.name] = remaining;
        }
        save(profile.name, remaining, committed);
        return ret;
    }

    bool accept(Profile profile, Event event)
    {
        if (receipts.get(profile.name, null).canFind(event.id))
            return false;
        foreach (pending; unread(profile))
        {
            if (pending.id == event.id)
                return false;
        }

        surface(profile, event);
        receipts[profile.name] ~= event.id.idup;
        if (receipts[profile.name].length > maxEvents)
            receipts[profile.name] = receipts[profile.name][$-maxEvents..$];

        atomicWrite(buildPath(inboxDir(profile.name), "receipts.json"), JSONValue(receipts[profile.name]).toString());
        return true;
    }

    void settle(Profile profile, Event[] batch, bool remove)
    {
        Event[] ret;
        foreach (event; unread(profile))
        {
            bool matched;
            foreach (entry; batch)
                matched = matched || entry.id == event.id;

            if (matched)
                event.deferred = false;
            if (!matched || !remove)
                ret ~= event;
        }

        pending[profile.name] = ret;
        save(profile.name);
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
        if (found.length > maxEvents)
            *found = (*found)[$-maxEvents..$];

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
    string inboxDir(string profileName) const
        => buildPath(directory, "inboxes", profileName);

    string eventsPath(string profileName) const
        => buildPath(inboxDir(profileName), eventsFile);

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
        save(profileName, pending.get(profileName, null));
    }

    void save(string profileName, Event[] batch)
    {
        bool committed;
        save(profileName, batch, committed);
    }

    void save(string profileName, Event[] batch, out bool committed)
    {
        JSONValue data = JSONValue.emptyArray;
        foreach (event; batch)
            data.array ~= event.toJSON();

        mkdirRecurse(inboxDir(profileName));
        atomicWrite(eventsPath(profileName), data.toString(), committed);
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
    bool deferred;

    string summary() const
    {
        final switch (type)
        {
        case EventType.Ping:
            return "ping from "~from;

        case EventType.Room:
            return "room "~room~" from "~from;

        case EventType.DM:
            return "dm from "~from;

        case EventType.Clock:
            return "clock";
        }
    }

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
        ret.timestamp = Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond;
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
        ret["deferred"] = JSONValue(deferred);
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

        if (data["id"].type != JSONType.string || !data["id"].str.length || data["type"].type != JSONType.string ||
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
        event.deferred = "deferred" in data.object && data["deferred"] == JSONValue(true);

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
