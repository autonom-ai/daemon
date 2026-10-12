module tests.events;

import autonom.agent;
import autonom.config;
import autonom.coord;
import autonom.coord.stream : HECTONANOSECONDS_PER_MILLISECOND;
import autonom.events.event;
import autonom.events.schedule;
import autonom.events.scheduler;
import autonom.interop;
import autonom.interop.devin;
import autonom.interop.devin.db : SessionMetadata;
import tests.common;
import arsd.sqlite;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : octal, to;
import std.datetime : Clock, UTC;
import std.file;
import std.json : JSONValue;
import std.path : buildPath;
import std.string : split, splitLines, strip;
import std.traits : hasUDA;
import std.typecons : Nullable;

private:

void installCli(Fixture fixture)
{
    write(fixture.config.devinCommand, `#!/bin/sh
export_path=
previous=
prompt=
for argument do
    if [ "$previous" = --export ]; then export_path=$argument; fi
    prompt=$argument
    previous=$argument
done
printf '%s\n' "$@" >> invocations.txt
printf -- '---\n' >> invocations.txt
[ -n "$DEVIN_COMPACTION_THRESHOLDS" ] && printf '%s' "$DEVIN_COMPACTION_THRESHOLDS" > compaction-thresholds.txt
[ "$prompt" = "Reply with exactly: OK" ] && exit 0
case "$1" in
    --print)
        count=0
        [ -f session-count.txt ] && count=$(cat session-count.txt)
        count=$((count + 1))
        printf '%s' "$count" > session-count.txt
        printf '{"session_id":"session-%s"}' "$count" > "$export_path"
        exit 0 ;;
esac
trap 'exit 0' TERM
while :; do sleep 0.05; done
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
}

void installFailingCli(Fixture fixture)
{
    write(fixture.config.devinCommand, `#!/bin/sh
export_path=
previous=
for argument do
    if [ "$previous" = --export ]; then export_path=$argument; fi
    previous=$argument
done
case "$1" in
    --print)
        printf '{"session_id":"failed-session"}' > "$export_path"
        exit 0 ;;
esac
exit 7
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
}

void writeSessionDatabase(
    string path,
    string id,
    string model,
    string directory
)
{
    Database database = new Sqlite(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    database.query("create table if not exists sessions (id text primary key, model text, working_directory text)");
    database.query(
        "insert or replace into sessions (id, model, working_directory) values (?, ?, ?)",
        id,
        model,
        directory
    );
}

string[] invocations(string workspace)
{
    string path = buildPath(workspace, "invocations.txt");
    if (!exists(path))
        return null;

    string[] ret;
    foreach (call; readText(path).split("---"))
    {
        if (call.strip.length)
            ret ~= call;
    }

    return ret;
}

bool argument(string call, string value)
{
    foreach (line; call.splitLines())
    {
        if (line == value)
            return true;
    }

    return false;
}

struct WakeFixture
{
    Fixture fixture;
    Config config;
    Devin bridge;
    ProfileStore store;
    Bus bus;
    EventStore events;
    ScheduleStore schedules;
    Scheduler scheduler;

    static WakeFixture create(string extra = null)
    {
        WakeFixture ret;
        ret.fixture = Fixture.create();
        scope(failure)
            ret.fixture.close();

        write(ret.fixture.path, "dataDir: data\nsessionLockDir: locks\ndevinCommand: "~
            JSONValue("./devin").toString()~"\n"~(extra is null ? "" : extra)~ROUTER);
        ret.config = new Config(ret.fixture.path);
        ret.bridge = new Devin(ret.config);
        ret.store = new ProfileStore(ret.config, ret.bridge);
        ret.events = new EventStore(ret.config, ret.store);
        ret.bus = new Bus(ret.config, ret.store);
        ret.schedules = new ScheduleStore(ret.config, ret.store);
        ret.scheduler = new Scheduler(ret.config, ret.bridge, ret.store, ret.events, ret.schedules);
        return ret;
    }

    Profile start(string name)
    {
        Execution execution = bridge.start("work", fixture.root, "");
        execution.wait();
        execution.status.should == ExecutionStatus.Succeeded;
        bridge.collect();
        return store.register(name, execution.sessionId);
    }

    void close()
    {
        bridge.close();
        fixture.close();
    }
}

Entry postedEntry(Profile from, string text, string room = null)
    => Entry.create(from.name, text, null, room);

public:

@Name("Events and schedules declare their module-level HTTP endpoints")
unittest
{
    static foreach (HANDLER; ["readEvents", "schedules", "schedule", "refreshSchedules"])
    {
        hasUDA!(mixin(HANDLER), endpoint).should == true;
        hasUDA!(mixin(HANDLER), route).should == true;
    }
}

@Name("Events surface once, persist, and clear by stream")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    EventStore events = new EventStore(fixture.config, fixture.store);
    events.surface(marlow, Event.create(EventType.Ping, "entry-1", "wren", "hello", "general"));
    events.surface(marlow, Event.create(EventType.Ping, "entry-1", "wren", "hello", "general"));
    events.surface(marlow, Event.create(EventType.Room, "entry-2", "wren", "work", "general"));
    events.unread(marlow).length.should == 2;

    EventStore reloaded = new EventStore(fixture.config, fixture.store);
    reloaded.unread(marlow).length.should == 2;
    Event[] read = reloaded.read(marlow);
    read.length.should == 2;
    read[0].type.should == EventType.Ping;
    read[0].text.should == "hello";
    read[1].room.should == "general";
    reloaded.unread(marlow).length.should == 0;
    new EventStore(fixture.config, fixture.store).unread(marlow).length.should == 0;

    EventStore cleared = new EventStore(fixture.config, fixture.store);
    cleared.surface(marlow, Event.create(EventType.Room, "entry-3", "wren", "work", "general"));
    cleared.surface(marlow, Event.create(EventType.Room, "entry-4", "wren", "work", "other"));
    cleared.surface(marlow, Event.create(EventType.DM, "entry-5", "wren", "psst"));
    cleared.clear(marlow, EventType.Room, "general");
    cleared.unread(marlow).length.should == 2;
    cleared.clear(marlow, EventType.DM);
    cleared.unread(marlow).length.should == 1;
    cleared.clear(marlow, EventType.Ping);
    cleared.unread(marlow).length.should == 1;
}

@Name("Schedules persist, match, and advance")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    ScheduleStore schedules = new ScheduleStore(fixture.config, fixture.store);
    Schedule ping = schedules.add(marlow, Schedule.create(EventType.Ping, "wren", null, null, 0, 0));
    Schedule room = schedules.add(marlow, Schedule.create(EventType.Room, null, "general", null, 0, 0));
    schedules.list(marlow).length.should == 2;

    ScheduleStore reloaded = new ScheduleStore(fixture.config, fixture.store);
    reloaded.list(marlow).length.should == 2;
    reloaded.list(wren).length.should == 0;
    reloaded.matching(EventType.Ping, null, "wren").length.should == 1;
    reloaded.matching(EventType.Ping, null, "quill").length.should == 0;
    reloaded.matching(EventType.Room, "general", "quill").length.should == 1;
    reloaded.matching(EventType.Room, "other", "quill").length.should == 0;

    long now = Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND;
    reloaded.add(marlow, Schedule.create(EventType.Clock, null, null, null, 60, now - 1));
    Match[] due = reloaded.due(Clock.currTime(UTC()));
    due.length.should == 1;
    reloaded.advance(marlow, due[0].schedule, Clock.currTime(UTC()));
    reloaded.due(Clock.currTime(UTC())).length.should == 0;
    reloaded.list(marlow).length.should == 3;
    (reloaded.list(marlow)[2].next > now).should == true;

    reloaded.add(marlow, Schedule.create(EventType.Clock, null, null, "2026-01-01T00:00:00Z", 0, now - 1));
    due = reloaded.due(Clock.currTime(UTC()));
    due.length.should == 1;
    reloaded.advance(marlow, due[0].schedule, Clock.currTime(UTC()));
    reloaded.list(marlow).length.should == 3;

    Nullable!Schedule removed = reloaded.remove(marlow, room.id);
    removed.isNull.should == false;
    removed.get.id.should == room.id;
    reloaded.remove(marlow, ping.id).isNull.should == false;
    reloaded.remove(marlow, ping.id).isNull.should == true;
    reloaded.list(marlow).length.should == 1;
}

@Name("Session metadata falls back to the CLI database")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.bridge.sessionMetadata("session-1").model.length.should == 0;
    writeSessionDatabase(fixture.config.sessionDatabase, "session-1", "SWE-2", fixture.root);
    SessionMetadata metadata = fixture.bridge.sessionMetadata("session-1");
    metadata.model.should == "SWE-2";
    metadata.directory.should == fixture.root;
    fixture.bridge.sessionMetadata("missing").directory.length.should == 0;
}

@Name("A ping wakes a recently offline session by resuming it")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    fixture.events.unread(marlow).length.should == 0;
    waitUntil(delegate bool()
    {
        return invocations(fixture.fixture.root).length == 2;
    });
    string[] calls = invocations(fixture.fixture.root);
    argument(calls[1], "--resume").should == true;
    argument(calls[1], marlow.session.id).should == true;
    calls[1].canFind("Reply with exactly: OK").should == false;
    calls[1].canFind("You were woken by 1 event").should == true;
    calls[1].canFind("- ping from wren: hello").should == true;
    calls[1].canFind("Continue your work.").should == true;

    fixture.scheduler.adopt("stranger", fixture.fixture.root).should == false;
    fixture.scheduler.posted(room, postedEntry(wren, "again", room.name), wren, [marlow]);
    fixture.events.unread(marlow).length.should == 1;
    Thread.sleep(200.msecs);
    invocations(fixture.fixture.root).length.should == 2;
}

@Name("A scheduled wake compacts before resuming")
unittest
{
    WakeFixture fixture = WakeFixture.create("offlineCompactAfter: 1s\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    fixture.schedules.add(marlow, Schedule.create(EventType.Ping, null, null, null, 0, 0));
    Thread.sleep(1100.msecs);
    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    waitUntil(delegate bool()
    {
        string[] calls = invocations(fixture.fixture.root);
        return calls.length >= 3;
    });
    string[] calls = invocations(fixture.fixture.root);
    argument(calls[1], "--resume").should == true;
    argument(calls[1], marlow.session.id).should == true;
    calls[1].canFind("Reply with exactly: OK").should == true;
    readText(buildPath(fixture.fixture.root, "compaction-thresholds.txt")).should == fixture.config.compactionThresholds;
    argument(calls[2], "--resume").should == true;
    calls[2].canFind("Reply with exactly: OK").should == false;
    calls[2].canFind("You were woken by 1 event").should == true;
    calls[2].canFind("- ping from wren: hello").should == true;
}

@Name("compactOnResume forces compaction before every resume")
unittest
{
    WakeFixture fixture = WakeFixture.create("compactOnResume: true\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    waitUntil(delegate bool()
    {
        return invocations(fixture.fixture.root).length >= 3;
    });
    string[] calls = invocations(fixture.fixture.root);
    calls[1].canFind("Reply with exactly: OK").should == true;
    readText(buildPath(fixture.fixture.root, "compaction-thresholds.txt")).should == fixture.config.compactionThresholds;
    argument(calls[2], "--resume").should == true;
    calls[2].canFind("Reply with exactly: OK").should == false;
    calls[2].canFind("- ping from wren: hello").should == true;
}

@Name("A stale ping starts a fresh session in the pinging workspace")
unittest
{
    WakeFixture fixture = WakeFixture.create("offlineStartAfter: 1s\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    writeSessionDatabase(fixture.config.sessionDatabase, marlow.session.id, "SWE-2", "/elsewhere");
    writeSessionDatabase(fixture.config.sessionDatabase, "session-2", "adaptive", fixture.fixture.root);
    Thread.sleep(1100.msecs);

    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    fixture.events.unread(marlow).length.should == 0;
    waitUntil(delegate bool()
    {
        return invocations(fixture.fixture.root).length == 2;
    });
    string[] calls = invocations(fixture.fixture.root);
    argument(calls[1], "--print").should == true;
    argument(calls[1], "--model").should == true;
    argument(calls[1], "SWE-2").should == true;
    argument(calls[1], "--resume").should == false;
    calls[1].canFind("This is a new session in wren's workspace.").should == true;

    fixture.scheduler.adopt("adopted", "/elsewhere").should == false;
    fixture.scheduler.adopt("adopted", fixture.fixture.root).should == true;
    fixture.store.get("marlow").session.id.should == "adopted";
    fixture.scheduler.adopt("adopted", fixture.fixture.root).should == false;
    fixture.scheduler.adopt("stranger", fixture.fixture.root).should == false;

    fixture.scheduler.refresh();
    fixture.store.get("marlow").session.id.should == "adopted";
    fixture.events.unread(marlow).length.should == 0;
}

@Name("A stale ping without a pinging workspace drops its event")
unittest
{
    WakeFixture fixture = WakeFixture.create("offlineStartAfter: 1s\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    Thread.sleep(1100.msecs);

    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    fixture.events.unread(marlow).length.should == 0;
    fixture.store.get("marlow").session.isRunning().should == false;
    invocations(fixture.fixture.root).length.should == 1;
}

@Name("Adoption skips ambiguous workspaces")
unittest
{
    WakeFixture fixture = WakeFixture.create("offlineStartAfter: 1s\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile quill = fixture.start("quill");
    Profile wren = fixture.store.register("wren", "session-3");
    writeSessionDatabase(fixture.config.sessionDatabase, "session-3", "adaptive", fixture.fixture.root);
    Thread.sleep(1100.msecs);

    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow, quill]);
    fixture.scheduler.adopt("stranger", fixture.fixture.root).should == false;
    fixture.scheduler.adopt("stranger", "/elsewhere").should == false;
    fixture.store.get("marlow").session.id.should == marlow.session.id;
    fixture.store.get("quill").session.id.should == quill.session.id;
}

@Name("A due clock schedule wakes its profile once")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    long now = Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND;
    fixture.schedules.add(marlow, Schedule.create(EventType.Clock, null, null, null, 0, now - 1));

    fixture.scheduler.refresh();

    fixture.schedules.list(marlow).length.should == 0;
    fixture.events.unread(marlow).length.should == 0;
    waitUntil(delegate bool()
    {
        return invocations(fixture.fixture.root).length == 2;
    });
    string[] calls = invocations(fixture.fixture.root);
    calls[1].canFind("- clock (scheduled wake)").should == true;

    fixture.scheduler.refresh();
    invocations(fixture.fixture.root).length.should == 2;
}

@Name("A failed wake re-surfaces its events")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    installFailingCli(fixture.fixture);

    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);
    fixture.events.unread(marlow).length.should == 0;

    waitUntil(delegate bool()
    {
        fixture.scheduler.refresh();
        return fixture.events.unread(marlow).length == 1;
    });
    fixture.events.unread(marlow)[0].text.should == "hello";

    fixture.scheduler.refresh();
    fixture.events.unread(marlow).length.should == 1;
}

@Name("Scheduled room and dm events wake matching profiles")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    Profile quill = fixture.store.register("quill", "session-3");
    fixture.schedules.add(marlow, Schedule.create(EventType.Room, "wren", "general", null, 0, 0));
    fixture.schedules.add(marlow, Schedule.create(EventType.DM, "wren", null, null, 0, 0));
    Room room = fixture.bus.createRoom("general", marlow.name);

    fixture.scheduler.posted(room, postedEntry(quill, "quiet", room.name), quill, null);
    fixture.scheduler.directed(marlow, postedEntry(quill, "psst"), quill, null);
    fixture.events.unread(marlow).length.should == 0;
    fixture.store.get("marlow").session.isRunning().should == false;
    invocations(fixture.fixture.root).length.should == 1;

    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, null);
    waitUntil(delegate bool()
    {
        return invocations(fixture.fixture.root).length == 2;
    });
    string[] calls = invocations(fixture.fixture.root);
    calls[1].canFind("- room general from wren: hello").should == true;
    calls[1].canFind("You were woken by 1 event").should == true;

    fixture.scheduler.directed(marlow, postedEntry(wren, "psst"), wren, null);
    fixture.events.unread(marlow).length.should == 1;
    fixture.events.unread(marlow)[0].type.should == EventType.DM;
    fixture.events.unread(marlow)[0].text.should == "psst";
    invocations(fixture.fixture.root).length.should == 2;
}
