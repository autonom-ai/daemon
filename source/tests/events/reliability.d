module tests.events.reliability;

import daemon.agent : Profile;
import daemon.coord : Entry, Room;
import daemon.events.delivery : posted;
import daemon.events.event : Event, EventStore, EventType, maxEvents;
import daemon.events.schedule : Schedule, ScheduleStore;
import daemon.events.scheduler : Scheduler;
import daemon.interop.acp : permissions, decide;
import daemon.interop.call : Call, CallStatus;
import daemon.interop.session : TurnStatus;
import tests.common : waitUntil;
import tests.events.common;

import unit_threaded : Name, should;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write, dirEntries, SpanMode;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;

@Name("A running session receives one event prompt on its existing connection")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    Profile sender = fixture.store.register("sender", "sender-session");
    Room room = fixture.bus.createRoom("general", sender.name);
    target.session.resume("hang", fixture.fixture.root);
    waitUntil(delegate bool() {
        return target.session.activity == TurnStatus.Running;
    });

    Entry entry = postedEntry(sender, "event-steer-once", room.name);
    fixture.scheduler.posted(room, entry, sender, [target]);
    waitForPrompt(fixture, "event-steer-once");
    fixture.scheduler.posted(room, entry, sender, [target]);
    waitUntil(delegate bool() {
        fixture.scheduler.refresh();
        return fixture.bridge.listCalls().length == 3 &&
            fixture.bridge.listCalls()[$-1].status == CallStatus.Succeeded;
    });
    promptTexts(fixture.fixture.root).length.should == 3;
    invocations(fixture.fixture.root).length.should == 2;
    fixture.events.unread(target).length.should == 0;
    fixture.bridge.collect();
    fixture.starts.refresh();
    fixture.scheduler.refresh();
    target.session.hasActiveCall().should == true;

    fixture.events = new EventStore(fixture.config, fixture.store);
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts);
    fixture.scheduler.posted(room, entry, sender, [target]);
    promptTexts(fixture.fixture.root).length.should == 3;
    fixture.events.unread(target).length.should == 0;
}

@Name("Scheduler start stop and restart tolerate failed loopback refresh without mutating stores")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    Profile target = fixture.store.register("target", "target-session");
    fixture.schedules.add(target, Schedule.create(EventType.Clock, null, null, null, 0, 1));
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts, "0");
    fixture.scheduler.start();
    fixture.scheduler.start();
    Thread.sleep(1100.msecs);
    MonoTime before = MonoTime.currTime;
    fixture.scheduler.stop();
    (MonoTime.currTime - before < 4.seconds).should == true;
    fixture.schedules.list(target).length.should == 1;
    fixture.events.unread(target).length.should == 0;
    fixture.scheduler.start();
    fixture.scheduler.stop();
    fixture.scheduler.stop();
}

@Name("An event during session load waits for admission instead of creating a second session")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    Profile sender = fixture.store.register("sender", "sender-session");
    Room room = fixture.bus.createRoom("general", sender.name);
    writeSessionDatabase(fixture.config.sessionDatabase, sender.session.id, "SWE-2", fixture.fixture.root);
    write(buildPath(fixture.fixture.root, "slow-load"), "");
    target.session.resume("hang", fixture.fixture.root);
    waitUntil(delegate bool() {
        foreach (call; acpCalls(fixture.fixture.root))
        {
            if (call["method"].str == "session/load")
                return true;
        }

        return false;
    });
    target.session.activity.should == TurnStatus.Unknown;
    fixture.scheduler.posted(room, postedEntry(sender, "after-load", room.name), sender, [target]);
    fixture.events.unread(target).length.should == 1;
    fixture.events.unread(target)[0].deferred.should == true;
    waitUntil(delegate bool() {
        return target.session.activity == TurnStatus.Running;
    });
    fixture.scheduler.refresh();
    waitForPrompt(fixture, "after-load");
    invocations(fixture.fixture.root).length.should == 2;
}

@Name("Unexpected child death produces an interrupted call independently of session liveness")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    target.session.resume("crash-mid-turn", fixture.fixture.root);
    target.session.execution.wait();
    target.session.execution.status.should == CallStatus.Interrupted;
    target.session.activity.should == TurnStatus.Idle;
    fixture.bridge.online(target.session.id).should == false;
}

@Name("A human permission wait defers events durably until the request settles")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    Profile sender = fixture.store.register("sender", "sender-session");
    Room room = fixture.bus.createRoom("general", sender.name);
    target.session.resume("permission", fixture.fixture.root);
    waitUntil(delegate bool() {
        return target.session.activity == TurnStatus.Waiting;
    });

    Entry entry = postedEntry(sender, "after-human-decision", room.name);
    fixture.schedules.add(target, Schedule.create(EventType.Clock, null, null, null, 0, 1));
    fixture.scheduler.refresh();
    fixture.scheduler.posted(room, entry, sender, [target]);
    fixture.events.unread(target).length.should == 2;
    fixture.events.unread(target)[0].deferred.should == true;
    promptTexts(fixture.fixture.root).length.should == 2;
    fixture.events = new EventStore(fixture.config, fixture.store);
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts);
    fixture.scheduler.refresh();
    promptTexts(fixture.fixture.root).length.should == 2;
    JSONValue pending = target.session.execution.connection.permissions(target.session.id);
    target.session.execution.connection.decide(target.session.id, pending[0]["id"].integer, "approve");
    target.session.execution.wait();
    fixture.scheduler.refresh();
    waitForPrompt(fixture, "after-human-decision");
    fixture.events.unread(target).length.should == 0;
    fixture.scheduler.posted(room, entry, sender, [target]);
    promptTexts(fixture.fixture.root).length.should == 3;
}

@Name("Clock occurrence identity survives schedule replay and scheduler restart")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    Schedule clock = Schedule.create(EventType.Clock, null, null, null, 0, 1);
    fixture.schedules.add(target, clock);
    fixture.scheduler.refresh();
    waitForPrompt(fixture, "scheduled wake");
    target.session.execution.wait();
    fixture.scheduler.refresh();
    fixture.schedules.add(target, clock);
    fixture.events = new EventStore(fixture.config, fixture.store);
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts);
    fixture.scheduler.refresh();
    promptTexts(fixture.fixture.root).length.should == 2;
    fixture.schedules.list(target).length.should == 0;
    parseJSON(readText(buildPath(fixture.schedules.directory, "wakes.json")))["wakes"].array.length.should == 0;
}

@Name("Corrupt wake files are preserved and do not prevent startup")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    Profile target = fixture.store.register("target", "target-session");
    fixture.events.surface(target, Event.create(EventType.Ping, "preserved", "sender", "inbox"));
    string path = buildPath(fixture.schedules.directory, "wakes.json");
    string damaged = `{"version":1,"wakes":[`;
    write(path, damaged);
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts);
    exists(path).should == false;
    size_t preserved;
    foreach (entry; dirEntries(fixture.schedules.directory, "wakes.json.corrupt-*", SpanMode.shallow))
    {
        readText(entry.name).should == damaged;
        preserved++;
    }
    preserved.should == 1;
    fixture.events.unread(target)[0].id.should == "preserved";
}

@Name("Wake recovery surfaces missing calls once and skips invalid rows")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    Profile target = fixture.store.register("target", "target-session");
    Event event = Event.create(EventType.Ping, "uncertain", "sender", "never-replay");
    JSONValue row = JSONValue([
        "execution": JSONValue("missing-call"),
        "profile": JSONValue(target.name),
        "session": JSONValue(target.session.id),
        "workspace": JSONValue(""),
        "events": JSONValue([event.toJSON()])
    ]);
    string path = buildPath(fixture.schedules.directory, "wakes.json");
    mkdirRecurse(fixture.schedules.directory);
    write(path, JSONValue(["version": JSONValue(1), "wakes": JSONValue([JSONValue(7), row])]).toString());
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
        fixture.events, fixture.schedules, fixture.starts);
    fixture.scheduler.refresh();
    fixture.events.unread(target).length.should == 1;
    fixture.events.unread(target)[0].deferred.should == false;
    fixture.scheduler.refresh();
    fixture.events.unread(target).length.should == 1;
    invocations(fixture.fixture.root).length.should == 0;
    parseJSON(readText(path))["wakes"].array.length.should == 0;
}

@Name("Event inbox and duplicate receipts stay bounded after reads and restart")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    Profile target = fixture.store.register("target", "target-session");
    foreach (i; 0..maxEvents + 2)
        fixture.events.accept(target, Event.create(EventType.Ping, i.to!string, "sender", "event"));

    fixture.events.unread(target).length.should == maxEvents;
    fixture.events.unread(target)[0].id.should == "2";
    fixture.events.read(target);
    fixture.events = new EventStore(fixture.config, fixture.store);
    fixture.events.accept(target, Event.create(EventType.Ping, "1001", "sender", "duplicate")).should == false;
    fixture.events.unread(target).length.should == 0;
}
