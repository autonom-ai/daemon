module tests.coord.cursors;

import daemon.agent : Profile, humanName;
import daemon.coord.stream : defaultMaxEntries;
import daemon.coord : Bus, Entry, Room;
import tests.common : Fixture;
import tests.coord.common : texts;

import unit_threaded : Name, should;

import std.conv : to;
import std.file : read;

@Name("Coordination trims the window and shifts cursors")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);
    foreach (i; 0..defaultMaxEntries + 1)
        bus.post(room, wren, "m"~i.to!string, null);

    Entry[] first = bus.readRoom(room, marlow, 50);
    first.length.should == 50;
    first[0].text.should == "m951";
    bus.post(room, wren, "m1001", null);
    texts(bus.readRoom(room, marlow, 50)).should == ["m1001"];
}

@Name("Coordination persists cursors and rooms across instances")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);
    bus.post(room, wren, "hello", null);
    bus.readRoom(room, marlow, 50).length.should == 1;

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");
    restored.name.should == "general";
    restored.owner.should == "wren";
    reloaded.readRoom(restored, marlow, 50).length.should == 0;
    reloaded.readRoom(restored, wren, 50).length.should == 1;
}

@Name("Coordination stream preserves active cursors and advances across rotation")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 5;
    Profile wren = fixture.store.register("wren", "session-2");
    Profile marlow = fixture.store.register("marlow", "session-1");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    bus.post(room, wren, "m0", null);
    Entry[] firstRead = bus.readRoom(room, marlow, 50);
    firstRead.length.should == 1;
    firstRead[0].text.should == "m0";

    foreach (i; 1..7)
        bus.post(room, wren, "m"~i.to!string, null);

    Entry[] secondRead = bus.readRoom(room, marlow, 50);
    texts(secondRead).should == ["m2", "m3", "m4", "m5", "m6"];
}

@Name("Coordination stress test: multi-reader, operator cursor, and multi-round trimming")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 4;

    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");
    Profile quill = fixture.store.register("quill", "session-quill");
    Profile human = new Profile(humanName);

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("stress", wren.name);

    // Initial state: human and marlow read empty room -> records cursor 0
    bus.readRoom(room, human, 10).length.should == 0;
    bus.readRoom(room, marlow, 10).length.should == 0;
    bus.hasCursor(humanName, "room:stress").should == true;
    bus.hasCursor("marlow", "room:stress").should == true;
    bus.hasCursor("quill", "room:stress").should == false; // quill has NOT read

    // 10 messages posted in batches
    foreach (i; 0..10)
        bus.post(room, wren, "msg-"~i.to!string, null);

    // Window size is 4, so stream currently contains [msg-6, msg-7, msg-8, msg-9].
    // Earlier messages [msg-0..msg-5] were trimmed.
    // Marlow and Human cursors started at 0 and were shifted with trimming down to 0.
    // Quill has no cursor recorded yet.

    // Marlow reads with limit 2: should read [msg-6, msg-7]
    texts(bus.readRoom(room, marlow, 2)).should == ["msg-6", "msg-7"];
    // Marlow reads next chunk: should read [msg-8, msg-9]
    texts(bus.readRoom(room, marlow, 2)).should == ["msg-8", "msg-9"];
    bus.readRoom(room, marlow, 2).length.should == 0;

    // Quill is a newcomer: first read with limit 2 should fast-forward to tail: [msg-8, msg-9]
    texts(bus.readRoom(room, quill, 2)).should == ["msg-8", "msg-9"];
    bus.readRoom(room, quill, 2).length.should == 0;

    // Restart bus and verify Human cursor survived and Human reads [msg-6, msg-7, msg-8, msg-9]
    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("stress");

    reloaded.hasCursor(humanName, "room:stress").should == true;
    texts(reloaded.readRoom(restored, human, 2)).should == ["msg-6", "msg-7"];
    texts(reloaded.readRoom(restored, human, 2)).should == ["msg-8", "msg-9"];
    reloaded.readRoom(restored, human, 2).length.should == 0;
}
