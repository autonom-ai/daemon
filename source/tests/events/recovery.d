module tests.events.recovery;

import daemon.agent : Profile, ProfileStore;
import daemon.coord : Entry, Room;
import daemon.events.delivery : posted;
import daemon.events.event : Event, EventType;
import daemon.events.scheduler : Scheduler;
import daemon.interop.devin.bridge : Bridge;
import tests.events.common;

import unit_threaded : Name, should;

import std.file : mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.uuid : randomUUID;

@Name("Wake restart reconciles success, failure, stop, interruption and missing calls without prompt replay")
unittest
{
    foreach (status; ["succeeded", "failed", "stopped", "interrupted", "running", "stopping", "missing"])
    {
        WakeFixture fixture = WakeFixture.create();
        scope(exit)
            fixture.close();
        Profile target = fixture.store.register("target", "old-session");
        string id = randomUUID().toString();
        Event event = Event.create(EventType.Ping, "recover-once", "sender", "never replay");
        JSONValue row = JSONValue([
            "execution": JSONValue(id),
            "profile": JSONValue(target.name),
            "session": JSONValue(null),
            "workspace": JSONValue(fixture.fixture.root),
            "events": JSONValue([event.toJSON()])
        ]);
        JSONValue missingProfile = parseJSON(row.toString());
        missingProfile["profile"] = JSONValue("gone");
        string path = buildPath(fixture.schedules.directory, "wakes.json");
        mkdirRecurse(fixture.schedules.directory);
        write(path, JSONValue([
            "version": JSONValue(1), "wakes": JSONValue([row, missingProfile])
        ]).toString());
        if (status != "missing")
        {
            mkdirRecurse(fixture.bridge.executionDir);
            JSONValue record = JSONValue([
                "status": JSONValue(status), "sessionId": JSONValue("late-session")
            ]);
            write(buildPath(fixture.bridge.executionDir, "index.json"), JSONValue([
                "version": JSONValue(1), "executions": JSONValue([id: record])
            ]).toString());
        }

        fixture.bridge.close();
        fixture.bridge = new Bridge(fixture.config);
        fixture.store = new ProfileStore(fixture.config, fixture.bridge);
        target = fixture.store.get("target");
        fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store,
            fixture.events, fixture.schedules);
        fixture.scheduler.refresh();
        target.session.id.should == (status == "succeeded" ? "late-session" : "old-session");
        fixture.events.unread(target).length.should == (status == "succeeded" ? 0 : 1);
        if (status != "succeeded")
            fixture.events.unread(target)[0].deferred.should == false;

        fixture.scheduler.refresh();
        invocations(fixture.fixture.root).length.should == 0;
        parseJSON(readText(path))["wakes"].array.length.should == 0;
    }
}

@Name("Scheduler restart retains an in-flight wake and surfaces a stopped wake exactly once")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();
    installCli(fixture.fixture);
    Profile target = fixture.start("target");
    Profile sender = fixture.store.register("sender", "sender-session");
    Room room = fixture.bus.createRoom("general", sender.name);
    write(buildPath(fixture.fixture.root, "hold-wake"), "");
    Entry entry = postedEntry(sender, "single-wake", room.name);
    fixture.scheduler.posted(room, entry, sender, [target]);
    waitForPrompt(fixture, "single-wake");
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store, fixture.events, fixture.schedules);
    fixture.scheduler.refresh();
    fixture.scheduler.posted(room, entry, sender, [target]);
    promptTexts(fixture.fixture.root).length.should == 2;
    string path = buildPath(fixture.schedules.directory, "wakes.json");
    parseJSON(readText(path))["wakes"].array.length.should == 1;
    target.session.stop();
    fixture.scheduler.refresh();
    fixture.events.unread(target).length.should == 1;
    fixture.events.unread(target)[0].deferred.should == false;
    parseJSON(readText(path))["wakes"].array.length.should == 0;
    fixture.scheduler = new Scheduler(fixture.config, fixture.bridge, fixture.store, fixture.events, fixture.schedules);
    fixture.scheduler.refresh();
    fixture.events.unread(target).length.should == 1;
    promptTexts(fixture.fixture.root).length.should == 2;
}
