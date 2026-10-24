module daemon.events.scheduler;

import daemon.agent;
import daemon.agent.starts : ProfileStarts;
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
import daemon.interop.session : Session, SessionStatus, TurnStatus;

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
    ProfileStarts starts;
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
        ScheduleStore schedules,
        ProfileStarts starts,
        string port = null
    )
    {
        this.config = configuration;
        this.bridge = bridge;
        this.store = store;
        this.events = events;
        this.schedules = schedules;
        this.starts = starts;
        this.port = port.length ? port.idup : environment.get("AUTONOM_PORT", "8080");
        this.loadWakes();
        publishNextDue();
    }

    void start()
    {
        if (thread !is null)
            return;

        atomicStore(stopping, false);
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
            Event event = Event.create(
                EventType.Clock,
                match.schedule.id~":"~match.schedule.next.to!string,
                null,
                clockText(match.schedule),
                null,
                match.schedule.id
            );
            deliver(match.profile, [event], null);
            schedules.advance(match.profile, match.schedule, now);
        }

        this.reconcile();
        foreach (profile; store.list())
        {
            Event[] batch;
            foreach (event; events.unread(profile))
            {
                if (event.deferred)
                    batch ~= event;
            }

            if (batch.length)
            {
                Profile from = batch[0].from.length ? store.get(batch[0].from) : null;
                dispatch(profile, batch, from);
            }
        }

        publishNextDue();
    }

    void publishNextDue()
    {
        long due = schedules.nextClock();
        foreach (profile; store.list())
        {
            foreach (event; events.unread(profile))
            {
                if (event.deferred)
                    due = 0;
            }
        }

        atomicStore(nextDue, due);
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
        => bridge.session(session.id).metadata;

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
            this.recordWake(execution, profile.name, session.id, null, batch);
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
            Call execution = starts.start(profile.name, wakePrompt(batch, from.name),
                workspace, targetModel(profile));
            this.recordWake(execution, profile.name, null, workspace, batch);
            return true;
        }
        catch (Exception)
            return false;
    }

    void deliver(Profile profile, Event[] batch, Profile from)
    {
        Event[] accepted;
        foreach (event; batch)
        {
            event.deferred = profile.name != humanName;
            if (events.accept(profile, event))
                accepted ~= event;
        }

        if (accepted.length)
            dispatch(profile, accepted, from);

        publishNextDue();
    }

    void dispatch(Profile profile, Event[] batch, Profile from)
    {
        if (profile.name == humanName || this.wakeInFlight(profile.name))
            return;

        Session session = profile.session;
        if (session !is null && !bridge.access.managed(session.id))
        {
            events.settle(profile, batch, false);
            return;
        }

        TurnStatus activity = session is null ? TurnStatus.Idle : session.activity;
        if (activity == TurnStatus.Waiting || activity == TurnStatus.Unknown)
            return;

        bool scheduled = from !is null && from.name == humanName;
        foreach (event; batch)
            scheduled = scheduled || event.schedule.length;

        bool loaded = session !is null && session.status == SessionStatus.Online;
        bool fresh = !loaded && !scheduled && (session is null || offline(session) > config.offlineStartAfter);
        string workspace = fresh ? pingerWorkspace(from) : null;
        if (fresh && !workspace.length)
        {
            events.settle(profile, batch, false);
            return;
        }

        // Persist the attempt before starting child work. A crash leaves advisory inbox
        // context, never an automatic replay of a prompt whose outcome is uncertain.
        events.settle(profile, batch, false);
        bool delivered;
        if (loaded || activity == TurnStatus.Running)
        {
            try
            {
                Call call = session.deliver(wakePrompt(batch, null));
                this.recordWake(call, profile.name, session.id, null, batch);
                delivered = true;
            }
            catch (Exception)
            { }
        }
        else if (fresh)
            delivered = start(profile, from, batch, workspace);
        else if (session !is null)
            delivered = resume(profile, session, batch);

        if (delivered)
            events.settle(profile, batch, true);
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
