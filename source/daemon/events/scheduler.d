module daemon.events.scheduler;

import daemon.agent;
import daemon.config;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.coord;
import daemon.events.delivery;
import daemon.events.event : Event, EventStore, EventType;
import daemon.events.prompt;
import daemon.events.schedule : ScheduleStore;
import daemon.events.wake;
import daemon.interop.call;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.provider : IProvider;
import daemon.interop.session : Session;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, seconds;
import std.conv : to;
import std.datetime : Clock, SysTime, UTC;
import std.file;
import std.net.curl : HTTP;
import std.process : environment;
import std.stdio : stderr;

enum wakesFile = "wakes.json";

class Scheduler
{
package(daemon.events):
    enum pollInterval = 1.seconds;

    Config config;
    IProvider bridge;
    ProfileStore store;
    EventStore events;
    ScheduleStore schedules;
    PendingWake[] pendingWakes;
    Thread thread;
    shared bool stopping;
    shared long nextDue = long.max;
    string port;

public:
    this(
        Config configuration,
        IProvider bridge,
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
        this.loadWakes();
        publishNextDue();
    }

    void start()
    {
        thread = new Thread({
            run();
        });
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

        this.reconcile();
        publishNextDue();
    }

    void publishNextDue()
    {
        atomicStore(nextDue, schedules.nextClock());
    }

package(daemon.events):
    Duration offline(Session session)
    {
        Call execution = session.execution;
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
        SessionMetadata ret = bridge.sessionMetadata(session.id);
        if (ret.id.length)
            return ret;

        Call execution = session.execution;
        if (execution !is null)
        {
            ret.model = execution.model;
            ret.directory = execution.workspace;
        }

        return ret;
    }

    string pingerWorkspace(Profile from)
        => from is null || from.session is null ? null : sessionInfo(from.session).directory;

    string targetModel(Profile profile)
        => profile.session is null ? null : sessionInfo(profile.session).model;

    bool resume(Profile profile, Session session, Event[] batch)
    {
        SessionMetadata info = sessionInfo(session);
        if (!info.directory.length)
            return false;

        string prompt = wakePrompt(batch, null);
        bool compact = config.compactOnResume || offline(session) > config.offlineCompactAfter;
        try
        {
            Call execution = bridge.resume(session.id, prompt, info.directory, info.model, compact);
            this.recordWake(execution.id, profile.name, session.id, null, batch);
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
            Call execution = bridge.start(wakePrompt(batch, from.name), workspace, targetModel(profile));
            this.recordWake(execution.id, profile.name, null, workspace, batch);
            return true;
        }
        catch (Exception)
            return false;
    }

    void deliver(Profile profile, Event[] batch, Profile from)
    {
        if (!batch.length)
            return;
        if (profile.name == humanName)
        {
            foreach (event; batch)
                events.surface(profile, event);

            return;
        }

        Session session = profile.session;
        if (session !is null && !bridge.access.managed(session.id))
        {
            foreach (event; batch)
                events.surface(profile, event);

            return;
        }

        bool profileOnline = session !is null && (session.isRunning() || bridge.online(session.id));
        bool hasWakeInFlight = this.wakeInFlight(profile.name);
        bool active = hasWakeInFlight || profileOnline;
        // TODO: Steer sessions for events or block?

        string profileState;
        if (profileOnline)
            profileState = "online";
        else if (session is null)
            profileState = "offline duration unknown";
        else
        {
            Duration offlineDuration = offline(session);
            if (offlineDuration == Duration.max)
                profileState = "offline duration unknown";
            else
                profileState = "offline for "~offlineDuration.to!string;
        }

        foreach (event; batch)
        {
            stderr.writefln(
                "autonom event_fired at=%s profile=%s type=%s schedule=%s state=\"%s\" wake_in_flight=%s",
                Clock.currTime(UTC()).toISOExtString(),
                profile.name,
                cast(string)event.type,
                event.schedule.length ? event.schedule : "none",
                profileState,
                hasWakeInFlight
            );
        }

        bool scheduled = from !is null && from.name == humanName;
        foreach (event; batch)
            scheduled = scheduled || event.schedule.length;

        bool fresh;
        string workspace;
        if (!active && !scheduled && (session is null || offline(session) > config.offlineStartAfter))
        {
            workspace = pingerWorkspace(from);
            if (workspace.length)
                fresh = true;
            else
            {
                foreach (event; batch)
                    events.surface(profile, event);
                return;
            }
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

    void poke()
    {
        try
        {
            HTTP client = HTTP("http://127.0.0.1:"~port~"/api/schedules/refresh");
            client.proxy = "";
            client.connectTimeout = 1.seconds;
            client.operationTimeout = 2.seconds;
            client.addRequestHeader("x-autonom-client", bridge.access.clientToken);
            client.setPostData("{}", "application/json");
            client.perform();
        }
        catch (Exception)
        { }
    }

    void run()
    {
        while (!atomicLoad(stopping))
        {
            Thread.sleep(pollInterval);
            if (atomicLoad(stopping))
                break;

            if (atomicLoad(nextDue) <= Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond)
                poke();
        }
    }
}
