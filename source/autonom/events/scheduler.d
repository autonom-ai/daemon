module autonom.events.scheduler;

import autonom.agent;
import autonom.config;
import autonom.coord;
import autonom.coord.stream : HECTONANOSECONDS_PER_MILLISECOND;
import autonom.events.event : Event, EventStore, EventType;
import autonom.events.schedule : SCHEDULES_FILE, Schedule, ScheduleStore;
import autonom.interop.devin;
import autonom.interop.devin.db : SessionMetadata;
import autonom.interop.execution;
import autonom.interop.session;
import autonom.storage;
import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, seconds;
import std.conv : to;
import std.datetime : Clock, SysTime, UTC;
import std.file;
import std.json : JSONType, JSONValue;
import std.net.curl : HTTP;
import std.path : buildNormalizedPath, buildPath;
import std.process : environment;

public:

enum WAKES_FILE = "wakes.json";

class Scheduler
{
public:
    this(
        Config configuration,
        Devin bridge,
        ProfileStore store,
        EventStore events,
        ScheduleStore schedules
    )
    {
        this.config = configuration;
        this.bridge = bridge;
        this.store = store;
        this.events = events;
        this.schedules = schedules;
        this.port = environment.get("AUTONOM_PORT", "8080");
        loadWakes();
    }

    void start()
    {
        thread = new Thread({ run(); });
        thread.start();
    }

    void stop()
    {
        atomicStore(stopping, true);
        if (thread !is null)
        {
            thread.join();
            thread = null;
        }
    }

    void refresh()
    {
        SysTime now = Clock.currTime(UTC());
        foreach (match; schedules.due(now))
        {
            schedules.advance(match.profile, match.schedule, now);
            Event event = Event.create(
                EventType.Clock,
                null,
                null,
                clockText(match.schedule),
                null,
                match.schedule.id
            );
            deliver(match.profile, [event], null);
        }

        reconcile();
    }

    void posted(
        Room room,
        Entry entry,
        Profile from,
        Profile[] targets
    )
    {
        Event[][string] batch;
        Profile[string] profiles;
        foreach (match; schedules.matching(EventType.Room, room.name, from.name))
        {
            if (match.profile.name == from.name || !room.visible(match.profile.name))
                continue;

            batch[match.profile.name] ~= Event.create(
                EventType.Room,
                entry.id,
                from.name,
                entry.text,
                room.name,
                match.schedule.id
            );
            profiles[match.profile.name] = match.profile;
        }

        foreach (target; targets)
        {
            if (target.name == from.name)
                continue;

            batch[target.name] ~= Event.create(
                EventType.Ping,
                entry.id,
                from.name,
                entry.text,
                room.name,
                pingSchedule(target, from.name)
            );
            profiles[target.name] = target;
        }

        foreach (name, events; batch)
            deliver(profiles[name], events, from);
    }

    void directed(
        Profile to,
        Entry entry,
        Profile from,
        Profile[] targets
    )
    {
        Event[][string] batch;
        Profile[string] profiles;
        foreach (match; schedules.matching(EventType.DM, null, from.name))
        {
            if (match.profile.name != to.name)
                continue;

            batch[match.profile.name] ~= Event.create(
                EventType.DM,
                entry.id,
                from.name,
                entry.text,
                null,
                match.schedule.id
            );
            profiles[match.profile.name] = match.profile;
        }

        foreach (target; targets)
        {
            if (target.name == from.name)
                continue;

            batch[target.name] ~= Event.create(
                EventType.Ping,
                entry.id,
                from.name,
                entry.text,
                null,
                pingSchedule(target, from.name)
            );
            profiles[target.name] = target;
        }

        foreach (name, events; batch)
            deliver(profiles[name], events, from);
    }

    bool adopt(string session, string directory)
    {
        if (!session.length || !directory.length)
            return false;

        Profile existing;
        try
            existing = store.profileFor(session);
        catch (Exception)
            return false;

        if (existing !is null)
            return false;

        directory = buildNormalizedPath(directory);
        size_t candidate = size_t.max;
        foreach (i, ref wake; pendingWakes)
        {
            if (wake.session.length || !wake.workspace.length)
                continue;
            if (buildNormalizedPath(wake.workspace) != directory)
                continue;
            if (candidate != size_t.max)
                return false;

            candidate = i;
        }

        if (candidate == size_t.max)
            return false;

        Profile profile = store.get(pendingWakes[candidate].profile);
        if (profile is null)
            return false;

        try
            store.register(profile.name, session);
        catch (Exception)
            return false;

        pendingWakes[candidate].session = session.idup;
        saveWakes();
        return true;
    }

private:
    enum POLL_INTERVAL = 1.seconds;

    Config config;
    Devin bridge;
    ProfileStore store;
    EventStore events;
    ScheduleStore schedules;
    PendingWake[] pendingWakes;
    Thread thread;
    shared bool stopping;
    string port;

    string wakesPath() const
        => buildPath(schedules.directory, WAKES_FILE);

    static bool parseWake(JSONValue data, out PendingWake wake)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["execution", "profile", "session", "workspace", "events"])
        {
            if (field !in data.object)
                return false;
        }

        if (data["execution"].type != JSONType.string || data["profile"].type != JSONType.string ||
            data["workspace"].type != JSONType.string || data["events"].type != JSONType.array)
            return false;
        if (!data["session"].isNull && data["session"].type != JSONType.string)
            return false;

        wake.execution = data["execution"].str.idup;
        wake.profile = data["profile"].str.idup;
        wake.session = data["session"].isNull ? null : data["session"].str.idup;
        wake.workspace = data["workspace"].str.idup;
        foreach (entry; data["events"].array)
        {
            Event event;
            if (!Event.parse(entry, event))
                return false;

            wake.events ~= event;
        }

        return true;
    }

    void loadWakes()
    {
        if (!exists(wakesPath))
            return;

        JSONValue data = readJSON(wakesPath, 4 * 1024 * 1024);
        if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
            "wakes" !in data.object || data["wakes"].type != JSONType.array)
            throw new Exception("Invalid pending wakes");

        foreach (entry; data["wakes"].array)
        {
            PendingWake wake;
            if (!parseWake(entry, wake))
                throw new Exception("Invalid pending wake");

            pendingWakes ~= wake;
        }
    }

    void saveWakes()
    {
        JSONValue data = JSONValue.emptyObject;
        data["version"] = JSONValue(1);
        data["wakes"] = JSONValue.emptyArray;
        foreach (wake; pendingWakes)
        {
            JSONValue eventsJSON = JSONValue.emptyArray;
            foreach (event; wake.events)
                eventsJSON.array ~= event.toJSON();

            data["wakes"].array ~= JSONValue([
                "execution": JSONValue(wake.execution),
                "profile": JSONValue(wake.profile),
                "session": wake.session.length ? JSONValue(wake.session) : JSONValue(null),
                "workspace": JSONValue(wake.workspace),
                "events": eventsJSON
            ]);
        }

        mkdirRecurse(schedules.directory);
        atomicWrite(wakesPath, data.toString());
    }

    void record(
        string execution,
        string profileName,
        string session,
        string workspace,
        Event[] batch
    )
    {
        PendingWake wake;
        wake.execution = execution;
        wake.profile = profileName;
        wake.session = session;
        wake.workspace = workspace;
        wake.events = batch;
        pendingWakes ~= wake;
        saveWakes();
    }

    bool wakeInFlight(string profileName)
    {
        foreach (wake; pendingWakes)
        {
            if (wake.profile == profileName)
                return true;
        }

        return false;
    }

    Duration offline(Session session)
    {
        Execution execution = session.execution;
        if (execution is null || !execution.finishedAt.length)
            return Duration.max;

        SysTime finished;
        try
            finished = SysTime.fromISOExtString(execution.finishedAt);
        catch (Exception)
            return Duration.max;

        SysTime now = Clock.currTime(UTC());
        return now > finished ? now - finished : Duration.zero;
    }

    SessionMetadata sessionInfo(Session session)
    {
        Execution execution = session.execution;
        SessionMetadata ret;
        if (execution !is null)
        {
            ret.model = execution.model;
            ret.directory = execution.workspace;
        }

        if (ret.model.length && ret.directory.length)
            return ret;

        SessionMetadata stored = bridge.sessionMetadata(session.id);
        if (!ret.model.length)
            ret.model = stored.model;
        if (!ret.directory.length)
            ret.directory = stored.directory;
        return ret;
    }

    string pingerWorkspace(Profile from)
        => from is null || from.session is null ? null : sessionInfo(from.session).directory;

    string targetModel(Profile profile)
        => profile.session is null ? null : sessionInfo(profile.session).model;

    string pingSchedule(Profile profile, string from)
    {
        foreach (match; schedules.matching(EventType.Ping, null, from))
        {
            if (match.profile.name == profile.name)
                return match.schedule.id;
        }

        return null;
    }

    string durationText(long value)
    {
        if (value % 86400 == 0)
            return (value / 86400).to!string~"d";
        if (value % 3600 == 0)
            return (value / 3600).to!string~"h";
        if (value % 60 == 0)
            return (value / 60).to!string~"m";

        return value.to!string~"s";
    }

    string clockText(Schedule schedule)
        => schedule.every ? "scheduled wake, repeats every "~durationText(schedule.every) : "scheduled wake";

    string eventCountText(size_t count)
        => count == 1 ? "1 event" : count.to!string~" events";

    string eventLine(Event event)
    {
        if (event.type == EventType.Clock)
            return "- "~event.summary~" ("~event.text~")";

        return "- "~event.summary~": "~event.text;
    }

    string wakePrompt(Event[] batch, string owner)
    {
        string ret = "You were woken by "~eventCountText(batch.length)~":\n\n";
        foreach (event; batch)
            ret ~= eventLine(event)~"\n";

        ret ~= "\n";
        ret ~= owner.length ? "This is a new session in "~owner~"'s workspace." : "Continue your work.";
        return ret;
    }

    bool resume(Profile profile, Session session, Event[] batch)
    {
        SessionMetadata info = sessionInfo(session);
        if (!info.directory.length)
            return false;

        string prompt = wakePrompt(batch, null);
        bool compact = config.compactOnResume || offline(session) > config.offlineCompactAfter;
        try
        {
            Execution execution;
            if (compact)
            {
                Execution preparation = bridge.compact(session.id, info.directory, info.model);
                execution = bridge.resume(session.id, prompt, info.directory, info.model, preparation);
            }
            else
                execution = bridge.resume(session.id, prompt, info.directory, info.model);

            record(execution.id, profile.name, session.id, null, batch);
            return true;
        }
        catch (Exception)
            return false;
    }

    bool start(
        Profile profile,
        Profile from,
        Event[] batch,
        string workspace
    )
    {
        try
        {
            Execution execution = bridge.start(wakePrompt(batch, from.name), workspace, targetModel(profile));
            record(execution.id, profile.name, null, workspace, batch);
            return true;
        }
        catch (Exception)
            return false;
    }

    void deliver(Profile profile, Event[] batch, Profile from)
    {
        if (!batch.length)
            return;

        Session session = profile.session;
        bool active = wakeInFlight(profile.name) ||
            (session !is null && (session.isRunning() || bridge.online(session.id)));

        bool scheduled;
        foreach (event; batch)
            scheduled = scheduled || event.schedule.length;

        bool fresh;
        string workspace;
        if (!active && !scheduled && (session is null || offline(session) > config.offlineStartAfter))
        {
            fresh = true;
            workspace = pingerWorkspace(from);
            if (!workspace.length)
                return;
        }

        if (!active)
        {
            if (fresh)
            {
                if (start(profile, from, batch, workspace))
                    return;
            }
            else if (session !is null)
            {
                if (resume(profile, session, batch))
                    return;
            }
        }

        foreach (event; batch)
            events.surface(profile, event);
    }

    void register(string profileName, string session)
    {
        Profile profile = store.get(profileName);
        if (profile is null)
            return;

        try
            store.register(profile.name, session);
        catch (Exception)
        {
        }
    }

    void reconcile()
    {
        if (!pendingWakes.length)
            return;

        PendingWake[] remaining;
        bool changed;
        foreach (wake; pendingWakes)
        {
            Execution execution = bridge.execution(wake.execution);
            if (execution !is null && execution.running)
            {
                remaining ~= wake;
                continue;
            }

            changed = true;
            if (execution !is null && execution.status == ExecutionStatus.Succeeded)
            {
                if (execution.kind == ExecutionKind.Start && execution.sessionId.length && !wake.session.length)
                    register(wake.profile, execution.sessionId);
            }
            else
            {
                Profile profile = store.get(wake.profile);
                if (profile !is null)
                {
                    foreach (event; wake.events)
                        events.surface(profile, event);
                }
            }
        }

        if (changed)
        {
            pendingWakes = remaining;
            saveWakes();
        }
    }

    long nextClock()
    {
        long ret = long.max;
        string inboxes = buildPath(schedules.directory, "inboxes");
        if (!exists(inboxes))
            return ret;

        foreach (DirEntry entry; dirEntries(inboxes, SpanMode.shallow))
        {
            if (!entry.isDir || entry.isSymlink)
                continue;

            string path = buildPath(entry.name, SCHEDULES_FILE);
            if (!exists(path))
                continue;

            JSONValue data;
            try
                data = readJSON(path, 4 * 1024 * 1024);
            catch (Exception)
                continue;

            if (data.type != JSONType.object || "schedules" !in data.object ||
                data["schedules"].type != JSONType.array)
                continue;

            foreach (scheduleJSON; data["schedules"].array)
            {
                Schedule schedule;
                if (!Schedule.parse(scheduleJSON, schedule))
                    continue;
                if (schedule.type == EventType.Clock && schedule.next && schedule.next < ret)
                    ret = schedule.next;
            }
        }

        return ret;
    }

    void poke()
    {
        try
        {
            HTTP client = HTTP("http://127.0.0.1:"~port~"/api/schedules/refresh");
            client.proxy = "";
            client.connectTimeout = 1.seconds;
            client.operationTimeout = 2.seconds;
            client.setPostData("{}", "application/json");
            client.perform();
        }
        catch (Exception)
        {
        }
    }

    void run()
    {
        while (!atomicLoad(stopping))
        {
            Thread.sleep(POLL_INTERVAL);
            if (atomicLoad(stopping))
                break;

            if (nextClock() <= Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND)
                poke();
        }
    }
}

private struct PendingWake
{
    string execution;
    string profile;
    string session;
    string workspace;
    Event[] events;
}
