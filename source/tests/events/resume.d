module tests.events.resume;

import daemon.agent : Profile;
import daemon.coord : Room;
import daemon.events.api : schedules;
import daemon.events.delivery : posted;
import daemon.events.event : EventType;
import daemon.events.schedule : Schedule;
import daemon.events.wake : adopt;
import tests.events.common : WakeFixture, installCli, invocations, acpCalls, promptTexts, waitForPrompt, postedEntry;

import unit_threaded : Name, should;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.json : JSONValue;

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
    waitForPrompt(fixture, "- ping from wren: hello");
    JSONValue[] calls = acpCalls(fixture.fixture.root);
    JSONValue[] loads;
    foreach (call; calls)
    {
        if (call["method"].str == "session/load")
            loads ~= call;
    }
    loads[$-1]["sessionId"].str.should == marlow.session.id;
    calls[$-1]["method"].str.should == "session/prompt";
    calls[$-1]["sessionId"].str.should == marlow.session.id;
    calls[$-1]["text"].str.canFind("/compact").should == false;
    calls[$-1]["text"].str.canFind("You were woken by 1 event").should == true;
    calls[$-1]["text"].str.canFind("- ping from wren: hello").should == true;
    calls[$-1]["text"].str.canFind("Continue your work.").should == true;

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

    waitForPrompt(fixture, "- ping from wren: hello");
    invocations(fixture.fixture.root).length.should == 2;
    string[] prompts = promptTexts(fixture.fixture.root);
    prompts[1].should == "/compact";
    prompts[2].canFind("/compact").should == false;
    prompts[2].canFind("You were woken by 1 event").should == true;
    prompts[2].canFind("- ping from wren: hello").should == true;
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

    waitForPrompt(fixture, "- ping from wren: hello");
    invocations(fixture.fixture.root).length.should == 2;
    string[] prompts = promptTexts(fixture.fixture.root);
    prompts[1].should == "/compact";
    prompts[2].canFind("/compact").should == false;
    prompts[2].canFind("- ping from wren: hello").should == true;
}
