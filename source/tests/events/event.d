module tests.events.event;

import daemon.agent : Profile;
import daemon.coord : Room;
import daemon.events.event : Event, EventStore, EventType;
import tests.common : Fixture;

import unit_threaded : Name, should;

import std.file : read, remove, rename, write;
import std.path : buildPath;

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

@Name("Event acknowledgement preserves later arrivals and other profiles across restart")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.create("marlow");
    Profile wren = fixture.store.create("wren");
    EventStore events = new EventStore(fixture.config, fixture.store);
    events.surface(marlow, Event.create(EventType.Ping, "shown", "human", "first"));
    events.surface(wren, Event.create(EventType.Ping, "foreign", "human", "other inbox"));
    events.unread(marlow).length.should == 1;
    events.surface(marlow, Event.create(EventType.Ping, "later", "human", "arrived after peek"));
    events.acknowledge(marlow, ["shown", "shown", "foreign", "unknown"]).should == ["shown"];
    events.acknowledge(marlow, ["shown"]).length.should == 0;
    events.acknowledge(marlow, null).length.should == 0;
    events.unread(marlow)[0].id.should == "later";
    events.unread(wren)[0].id.should == "foreign";

    EventStore reloaded = new EventStore(fixture.config, fixture.store);
    reloaded.unread(marlow).length.should == 1;
    reloaded.unread(marlow)[0].id.should == "later";
    reloaded.unread(wren)[0].id.should == "foreign";
}

@Name("Failed event acknowledgement does not consume the in-memory inbox")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile profile = fixture.store.create("marlow");
    EventStore events = new EventStore(fixture.config, fixture.store);
    events.surface(profile, Event.create(EventType.Ping, "shown", "human", "retain on failure"));
    string inbox = buildPath(events.directory, "inboxes", profile.name);
    string backup = inbox~"-backup";
    rename(inbox, backup);
    scope(exit)
    {
        remove(inbox);
        rename(backup, inbox);
    }
    write(inbox, "not a directory");

    bool failed;
    try
        events.acknowledge(profile, ["shown"]);
    catch (Exception)
        failed = true;

    failed.should == true;
    events.unread(profile).length.should == 1;
    events.unread(profile)[0].id.should == "shown";
}
