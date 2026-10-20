module tests.events.wake;

import daemon.agent : Profile;
import daemon.agent.api : profiles;
import daemon.coord : Room;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.events.api : readEvents, schedules, schedule, refreshSchedules;
import daemon.events.delivery : posted, directed;
import daemon.events.event : EventType;
import daemon.events.schedule : Schedule;
import tests.common : waitUntil;
import tests.events.common : WakeFixture, installCli, installFailingCli, invocations, promptTexts, waitForPrompt, postedEntry;

import serverino : endpoint, route;
import unit_threaded : Name, should;

import std.algorithm.searching : canFind;
import std.datetime : Clock, UTC;
import std.traits : hasUDA;

@Name("Events and schedules declare their module-level HTTP endpoints")
unittest
{
    static foreach (handler; ["readEvents", "schedules", "schedule", "refreshSchedules"])
    {
        hasUDA!(mixin(handler), endpoint).should == true;
        hasUDA!(mixin(handler), route).should == true;
    }
}

@Name("A due clock schedule wakes its profile once")
unittest
{
    WakeFixture fixture = WakeFixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    long now = Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond;
    fixture.schedules.add(marlow, Schedule.create(EventType.Clock, null, null, null, 0, now - 1));

    fixture.scheduler.refresh();

    fixture.schedules.list(marlow).length.should == 0;
    fixture.events.unread(marlow).length.should == 0;
    waitForPrompt(fixture, "- clock (scheduled wake)");

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

    waitUntil(delegate bool() {
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
    fixture.store.get("marlow").session.hasActiveCall().should == false;
    invocations(fixture.fixture.root).length.should == 1;

    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, null);
    waitForPrompt(fixture, "- room general from wren: hello");
    invocations(fixture.fixture.root).length.should == 2;
    string[] prompts = promptTexts(fixture.fixture.root);
    prompts[$-1].canFind("You were woken by 1 event").should == true;

    fixture.scheduler.directed(marlow, postedEntry(wren, "psst"), wren, null);
    fixture.events.unread(marlow).length.should == 1;
    fixture.events.unread(marlow)[0].type.should == EventType.DM;
    fixture.events.unread(marlow)[0].text.should == "psst";
    invocations(fixture.fixture.root).length.should == 2;
}
