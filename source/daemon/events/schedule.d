module daemon.events.schedule;

import daemon.agent;
import daemon.api;
import daemon.config;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.events.event : EventType, parseEventType;
import daemon.exception;
import daemon.storage;

import serverino;

import std.datetime : Clock, SysTime;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.typecons : Nullable;
import std.uuid : randomUUID;

enum schedulesFile = "schedules.json";
enum maxSchedules = 100;
enum maxEvery = 30 * 86400;

class ScheduleStore
{
private:
    ProfileStore store;
    Schedule[][string] schedules;

public:
    const string directory;

    this(Config configuration, ProfileStore store)
    {
        this.store = store;
        directory = buildPath(configuration.dataDir, "coord");
        if (exists(directory) && isSymlink(directory))
            throw new Exception("Coordination directory must not be a symlink");

        foreach (Profile profile; store.list())
            schedules[profile.name] = load(profile.name);
    }

    Schedule[] list(Profile profile)
    {
        Schedule[]* found = profile.name in schedules;
        return found is null ? null : (*found).dup;
    }

    Schedule add(Profile profile, Schedule schedule)
    {
        if (profile.name !in schedules)
            schedules[profile.name] = null;

        Schedule[]* found = profile.name in schedules;
        if (found.length >= maxSchedules)
            throw new ConflictException("Too many schedules");

        *found ~= schedule;
        save(profile.name);
        return schedule;
    }

    Nullable!Schedule remove(Profile profile, string id)
    {
        Schedule[]* found = profile.name in schedules;
        if (found is null)
            return Nullable!Schedule.init;

        Schedule ret;
        Schedule[] remaining;
        foreach (schedule; *found)
        {
            if (ret.id.length || schedule.id != id)
                remaining ~= schedule;
            else
                ret = schedule;
        }

        if (!ret.id.length)
            return Nullable!Schedule.init;

        *found = remaining;
        save(profile.name);
        return Nullable!Schedule(ret);
    }

    long nextClock()
    {
        long ret = long.max;
        foreach (profileSchedules; schedules)
        {
            foreach (schedule; profileSchedules)
            {
                if (schedule.type == EventType.Clock && schedule.next && schedule.next < ret)
                    ret = schedule.next;
            }
        }

        return ret;
    }

    Match[] due(SysTime now)
    {
        long timestamp = now.stdTime / stdTimeTicksPerMillisecond;
        Match[] ret;
        foreach (profileName, profileSchedules; schedules)
        {
            Profile profile = store.get(profileName);
            if (profile is null)
                continue;

            foreach (schedule; profileSchedules)
            {
                if (schedule.type == EventType.Clock && schedule.next && schedule.next <= timestamp)
                    ret ~= Match(profile, schedule);
            }
        }

        return ret;
    }

    void advance(Profile profile, Schedule schedule, SysTime now)
    {
        Schedule[]* found = profile.name in schedules;
        if (found is null)
            return;

        long timestamp = now.stdTime / stdTimeTicksPerMillisecond;
        Schedule[] remaining;
        bool changed;
        foreach (entry; *found)
        {
            if (entry.id != schedule.id)
            {
                remaining ~= entry;
                continue;
            }

            changed = true;
            if (entry.every > 0)
            {
                entry.next = timestamp + entry.every * 1000;
                remaining ~= entry;
            }
        }

        if (changed)
        {
            *found = remaining;
            save(profile.name);
        }
    }

    Match[] matching(EventType type, string room, string from)
    {
        Match[] ret;
        foreach (profileName, profileSchedules; schedules)
        {
            Profile profile = store.get(profileName);
            if (profile is null)
                continue;

            foreach (schedule; profileSchedules)
            {
                if (schedule.type != type)
                    continue;
                if (schedule.room.length && schedule.room != room)
                    continue;
                if (schedule.from.length && schedule.from != from)
                    continue;

                ret ~= Match(profile, schedule);
            }
        }

        return ret;
    }

private:
    string schedulesPath(string profileName) const
        => buildPath(directory, "inboxes", profileName, schedulesFile);

    Schedule[] load(string profileName)
    {
        string path = schedulesPath(profileName);
        if (!exists(path))
            return null;

        JSONValue data = readJSON(path, 4 * 1024 * 1024);
        if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
            "schedules" !in data.object || data["schedules"].type != JSONType.array)
            throw new Exception("Invalid schedules");

        Schedule[] ret;
        foreach (entry; data["schedules"].array)
        {
            Schedule schedule;
            if (!Schedule.parse(entry, schedule))
                throw new Exception("Invalid schedule");

            ret ~= schedule;
        }

        return ret;
    }

    void save(string profileName)
    {
        JSONValue data = JSONValue.emptyObject;
        data["version"] = JSONValue(1);
        data["schedules"] = JSONValue.emptyArray;
        Schedule[]* found = profileName in schedules;
        if (found !is null)
        {
            foreach (schedule; *found)
                data["schedules"].array ~= schedule.toJSON();
        }

        mkdirRecurse(buildPath(directory, "inboxes", profileName));
        atomicWrite(schedulesPath(profileName), data.toString());
    }
}

struct Match
{
    Profile profile;
    Schedule schedule;
}

struct Schedule
{
    string id;
    EventType type;
    string from;
    string room;
    string at;
    long every;
    long next;

    static Schedule create(
        EventType type,
        string from,
        string room,
        string at,
        long every,
        long next
    )
    {
        Schedule ret;
        ret.id = randomUUID().toString();
        ret.type = type;
        ret.from = from;
        ret.room = room;
        ret.at = at;
        ret.every = every;
        ret.next = next;
        return ret;
    }

    JSONValue toJSON() const
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["id"] = JSONValue(id);
        ret["type"] = JSONValue(cast(string)type);
        ret["from"] = from.length ? JSONValue(from) : JSONValue(null);
        ret["room"] = room.length ? JSONValue(room) : JSONValue(null);
        ret["at"] = at.length ? JSONValue(at) : JSONValue(null);
        ret["every"] = every ? JSONValue(every) : JSONValue(null);
        ret["next"] = JSONValue(next);
        return ret;
    }

    static bool parse(JSONValue data, out Schedule schedule)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["id", "type", "next"])
        {
            if (field !in data.object)
                return false;
        }

        if (data["id"].type != JSONType.string || data["type"].type != JSONType.string ||
            data["next"].type != JSONType.integer)
            return false;

        EventType type;
        if (!parseEventType(data["type"].str, type))
            return false;

        schedule.id = data["id"].str.idup;
        schedule.type = type;
        schedule.next = data["next"].integer;
        if ("from" in data.object && data["from"].type == JSONType.string)
            schedule.from = data["from"].str.idup;
        if ("room" in data.object && data["room"].type == JSONType.string)
            schedule.room = data["room"].str.idup;
        if ("at" in data.object && data["at"].type == JSONType.string)
            schedule.at = data["at"].str.idup;
        if ("every" in data.object && data["every"].type == JSONType.integer)
            schedule.every = data["every"].integer;

        return true;
    }
}
