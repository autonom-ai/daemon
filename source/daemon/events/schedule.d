module daemon.events.schedule;

import daemon.agent;
import daemon.config;
import daemon.coord;
import daemon.coord.stream : HECTONANOSECONDS_PER_MILLISECOND;
import daemon.events.event : EventType, parseEventType;
import daemon.exception;
import daemon.http;
import daemon.runtime;
import daemon.storage;
import serverino;

import std.conv : to;
import std.datetime : Clock, SysTime, UTC;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.typecons : Nullable;
import std.uuid : randomUUID;

public:

@endpoint @route!"/api/schedules"
void schedules(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (schedule; scheduleStore.list(profile))
            ret ~= schedule.toJSON();

        respond(output, JSONValue(ret));
        return;
    }

    Nullable!Schedule schedule = readSchedule(profile, readBody(request), output);
    if (schedule.isNull)
        return;

    if (scheduler !is null)
        scheduler.publishNextDue();
    respond(output, schedule.get.toJSON(), 201);
}

@endpoint @route!(matchesPath!"/api/schedules/<id>")
void schedule(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Delete]))
        return;

    Profile profile = caller(request);
    Nullable!Schedule removed = scheduleStore.remove(profile, routeParameter!"/api/schedules/<id>"(request));
    if (removed.isNull)
        respondError(output, 404, "Schedule not found");
    else
    {
        if (scheduler !is null)
            scheduler.publishNextDue();

        respond(output, removed.get.toJSON());
    }
}

@priority(10) @endpoint @route!"/api/schedules/refresh"
void refreshSchedules(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");

    respond(output, JSONValue(cast(JSONValue[string])null));
}

enum SCHEDULES_FILE = "schedules.json";
enum MAX_SCHEDULES = 100;
enum MAX_EVERY = 30 * 86400;

class ScheduleStore
{
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
        if (found.length >= MAX_SCHEDULES)
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
        long timestamp = now.stdTime / HECTONANOSECONDS_PER_MILLISECOND;
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

        long timestamp = now.stdTime / HECTONANOSECONDS_PER_MILLISECOND;
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
    ProfileStore store;
    Schedule[][string] schedules;

    string schedulesPath(string profileName) const
        => buildPath(directory, "inboxes", profileName, SCHEDULES_FILE);

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

private:

Nullable!Schedule readSchedule(Profile profile, JSONValue data, Output output)
{
    onlyFields(data, ["type", "from", "room", "at", "every"]);
    if ("type" !in data.object || data["type"].type != JSONType.string)
        throw new InvalidInputException("A schedule needs a type");

    EventType type;
    if (!parseEventType(data["type"].str, type))
        throw new InvalidInputException("Unknown schedule type");

    string from;
    if ("from" in data.object && !data["from"].isNull)
    {
        if (data["from"].type != JSONType.string)
            throw new InvalidInputException("from must be a profile name");

        Profile sender = profileStore.get(data["from"].str);
        if (sender is null)
            throw new InvalidInputException("Unknown profile");

        from = sender.name;
    }

    string room;
    if (type == EventType.Room)
    {
        if ("room" !in data.object || data["room"].type != JSONType.string)
            throw new InvalidInputException("A room schedule needs a room");

        Room found = bus.getRoom(data["room"].str);
        if (found is null || !found.visible(profile.name))
        {
            respondError(output, 404, "Unknown room");
            return Nullable!Schedule.init;
        }

        room = found.name;
    }
    else if ("room" in data.object && !data["room"].isNull)
        throw new InvalidInputException("Only room schedules take a room");

    string at;
    long every;
    long next;
    if (type == EventType.Clock)
    {
        bool hasAt = "at" in data.object && !data["at"].isNull;
        bool hasEvery = "every" in data.object && !data["every"].isNull;
        if (hasAt == hasEvery)
            throw new InvalidInputException("A clock schedule needs either at or every");

        long timestamp = Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND;
        if (hasAt)
        {
            if (data["at"].type != JSONType.string)
                throw new InvalidInputException("at must be an ISO-8601 timestamp");

            SysTime time;
            try
                time = SysTime.fromISOExtString(data["at"].str);
            catch (Exception)
                throw new InvalidInputException("at must be an ISO-8601 timestamp");

            time = time.toUTC();
            if (time.stdTime / HECTONANOSECONDS_PER_MILLISECOND <= timestamp)
                throw new InvalidInputException("at must be in the future");

            at = time.toISOExtString();
            next = time.stdTime / HECTONANOSECONDS_PER_MILLISECOND;
        }
        else
        {
            if (data["every"].type != JSONType.integer || data["every"].integer < 1 ||
                data["every"].integer > MAX_EVERY)
                throw new InvalidInputException("every must be a number of seconds up to "~MAX_EVERY.to!string);

            every = data["every"].integer;
            next = timestamp + every * 1000;
        }
    }
    else if (("at" in data.object && !data["at"].isNull) || ("every" in data.object && !data["every"].isNull))
        throw new InvalidInputException("Only clock schedules take at or every");

    return Nullable!Schedule(scheduleStore.add(profile, Schedule.create(type, from, room, at, every, next)));
}
