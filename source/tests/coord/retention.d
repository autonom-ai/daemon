module tests.coord.retention;

import daemon.agent : Profile;
import daemon.coord : Bus, Entry, Room;
import tests.common : Fixture;
import tests.coord.common : texts;

import unit_threaded : Name, should;

import std.conv : to;

@Name("Coordination stream preserves unread messages across reload after window trimming")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 5;
    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    foreach (i; 0..5)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1", "m2", "m3", "m4"];
    bus.readRoom(room, marlow, 50).length.should == 0;

    foreach (i; 5..10)
        bus.post(room, wren, "m"~i.to!string, null);

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");

    Entry[] unread = reloaded.readRoom(restored, marlow, 50);
    texts(unread).should == ["m5", "m6", "m7", "m8", "m9"];
    reloaded.readRoom(restored, marlow, 50).length.should == 0;
}

@Name("Coordination stream preserves partial unread messages and respects limit across reload")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 5;
    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    foreach (i; 0..3)
        bus.post(room, wren, "m"~i.to!string, null);

    bus.readRoom(room, marlow, 50).length.should == 3;

    foreach (i; 3..8)
        bus.post(room, wren, "m"~i.to!string, null);

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");

    Entry[] firstBatch = reloaded.readRoom(restored, marlow, 2);
    firstBatch.length.should == 2;
    firstBatch[0].text.should == "m3";
    firstBatch[1].text.should == "m4";

    Entry[] secondBatch = reloaded.readRoom(restored, marlow, 50);
    secondBatch.length.should == 3;
    secondBatch[0].text.should == "m5";
    secondBatch[2].text.should == "m7";
    reloaded.readRoom(restored, marlow, 50).length.should == 0;
}

@Name("Coordination stream preserves unread messages across reload after partial window trimming")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 5;
    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    foreach (i; 0..3)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1", "m2"];
    bus.readRoom(room, marlow, 50).length.should == 0;

    foreach (i; 3..8)
        bus.post(room, wren, "m"~i.to!string, null);

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");

    Entry[] unread = reloaded.readRoom(restored, marlow, 50);
    texts(unread).should == ["m3", "m4", "m5", "m6", "m7"];
    reloaded.readRoom(restored, marlow, 50).length.should == 0;
}

@Name("Coordination stream preserves independent cursors for active and lagging readers across reload")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 5;
    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");
    Profile quill = fixture.store.register("quill", "session-quill");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    foreach (i; 0..2)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1"];
    texts(bus.readRoom(room, quill, 50)).should == ["m0", "m1"];

    foreach (i; 2..5)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m2", "m3", "m4"];

    foreach (i; 5..8)
        bus.post(room, wren, "m"~i.to!string, null);

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");

    Entry[] marlowUnread = reloaded.readRoom(restored, marlow, 50);
    texts(marlowUnread).should == ["m5", "m6", "m7"];
    reloaded.readRoom(restored, marlow, 50).length.should == 0;

    Entry[] quillUnread = reloaded.readRoom(restored, quill, 50);
    texts(quillUnread).should == ["m3", "m4", "m5", "m6", "m7"];
    reloaded.readRoom(restored, quill, 50).length.should == 0;

    reloaded.post(restored, wren, "m8", null);
    texts(reloaded.readRoom(restored, marlow, 50)).should == ["m8"];
    texts(reloaded.readRoom(restored, quill, 50)).should == ["m8"];
    reloaded.readRoom(restored, marlow, 50).length.should == 0;
    reloaded.readRoom(restored, quill, 50).length.should == 0;
}
