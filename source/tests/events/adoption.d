module tests.events.adoption;

import daemon.agent : Profile;
import daemon.coord : Room;
import daemon.events.delivery : posted;
import daemon.events.event : EventType;
import daemon.events.wake : adopt;
import tests.events.common : WakeFixture, installCli, writeSessionDatabase, invocations, acpCalls, waitForPrompt, postedEntry;

import unit_threaded : Name, should;

import core.thread : Thread;
import core.time : msecs;
import std.path : buildPath;
import std.json : JSONValue;

@Name("A stale ping starts a fresh session in the pinging workspace")
unittest
{
    WakeFixture fixture = WakeFixture.create("offlineStartAfter: 1s\n");
    scope(exit)
        fixture.close();

    installCli(fixture.fixture);
    Profile marlow = fixture.start("marlow");
    Profile wren = fixture.store.register("wren", "session-2");
    writeSessionDatabase(buildPath(fixture.config.dataDir, "cli", "sessions.db"), marlow.session.id, "SWE-2", "/elsewhere");
    writeSessionDatabase(fixture.config.sessionDatabase, "session-2", "adaptive", fixture.fixture.root);
    Thread.sleep(1100.msecs);

    Room room = fixture.bus.createRoom("general", wren.name);
    fixture.scheduler.posted(room, postedEntry(wren, "hello", room.name), wren, [marlow]);

    fixture.events.unread(marlow).length.should == 0;
    waitForPrompt(fixture, "This is a new session in wren's workspace.");
    JSONValue[] calls = acpCalls(fixture.fixture.root);
    size_t created;
    foreach (i, call; calls)
    {
        if ("method" in call.object && call["method"].str == "session/new")
            created = i;
    }

    bool modelApplied;
    foreach (call; calls[created + 1..$])
    {
        if (call["method"].str == "session/load")
            modelApplied = false;
        if (call["method"].str == "session/set_config_option" &&
            call["configId"].str == "model" && call["value"].str == "SWE-2")
            modelApplied = true;
    }

    modelApplied.should == true;

    fixture.scheduler.adopt("adopted", "/elsewhere").should == false;
    fixture.scheduler.adopt("adopted", fixture.fixture.root).should == true;
    fixture.store.get("marlow").session.id.should == "adopted";
    fixture.scheduler.adopt("adopted", fixture.fixture.root).should == false;
    fixture.scheduler.adopt("stranger", fixture.fixture.root).should == false;

    fixture.scheduler.refresh();
    fixture.store.get("marlow").session.id.should == "adopted";
    fixture.events.unread(marlow).length.should == 0;
}

@Name("A stale ping without a pinging workspace surfaces its event")
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

    fixture.events.unread(marlow).length.should == 1;
    fixture.events.unread(marlow)[0].type.should == EventType.Ping;
    fixture.events.unread(marlow)[0].text.should == "hello";
    fixture.events.unread(marlow)[0].from.should == "wren";
    fixture.store.get("marlow").session.hasActiveCall().should == false;
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
