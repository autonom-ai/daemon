module tests.events.event;

import daemon.agent : Profile;
import daemon.coord : Room;
import daemon.events.event : Event, EventStore, EventType;
import tests.common : Fixture;

import unit_threaded : Name, should;

import std.file : read;

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
