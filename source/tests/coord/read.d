module tests.coord.read;

import daemon.agent : Profile;
import daemon.coord : Bus, Entry, Room;
import tests.common : Fixture;
import tests.coord.common : texts;

import unit_threaded : Name, should;

import core.sys.posix.sys.stat : stat, stat_t;
import std.conv : to;
import std.file : exists, read, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.string : toStringz;

@Name("Coordination stream does not fast-forward shifted zero cursor when reading with small limit")
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

    foreach (i; 0..2)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1"];

    foreach (i; 2..7)
        bus.post(room, wren, "m"~i.to!string, null);

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");

    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m2", "m3"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m4", "m5"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m6"];
    reloaded.readRoom(restored, marlow, 2).length.should == 0;
}

@Name("Coordination reading empty stream records and persists cursor 0")
unittest
{

    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-marlow");
    Profile wren = fixture.store.register("wren", "session-wren");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    bus.hasCursor("marlow", "room:general").should == false;
    bus.cursor("marlow", "room:general").should == 0;

    string cursorsPath = buildPath(fixture.config.dataDir, "coord", "inboxes", "marlow", "cursors.json");
    exists(cursorsPath).should == false;

    // Read empty room
    Entry[] entries = bus.readRoom(room, marlow, 50);
    entries.length.should == 0;

    // Verify in-memory state
    bus.hasCursor("marlow", "room:general").should == true;
    bus.cursor("marlow", "room:general").should == 0;

    // Verify on-disk persistence
    exists(cursorsPath).should == true;
    JSONValue saved = parseJSON(readText(cursorsPath));
    saved.type.should == JSONType.object;
    (("room:general" in saved.object) !is null).should == true;
    saved.object["room:general"].integer.should == 0;

    // Reload bus and verify cursor survives restart
    Bus reloaded = new Bus(fixture.config, fixture.store);
    Room restored = reloaded.getRoom("general");
    reloaded.hasCursor("marlow", "room:general").should == true;
    reloaded.cursor("marlow", "room:general").should == 0;

    // Now post entries and verify marlow does NOT fast-forward (reads from index 0)
    foreach (i; 0..5)
        reloaded.post(restored, wren, "m"~i.to!string, null);

    // Limit is 2, target has 5 entries. Because cursor was established at 0, should read m0, m1!
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m0", "m1"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m2", "m3"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m4"];
    reloaded.readRoom(restored, marlow, 2).length.should == 0;
}

@Name("Coordination idle reader at cursor 0 does not repeatedly save cursors on stream trim")
unittest
{

    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamEntries = 2;
    Profile wren = fixture.store.register("wren", "session-wren");
    Profile marlow = fixture.store.register("marlow", "session-marlow");

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);

    // Post 2 entries
    bus.post(room, wren, "m0", null);
    bus.post(room, wren, "m1", null);

    // Marlow reads both entries
    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1"];
    bus.cursor("marlow", "room:general").should == 2;

    string cursorsPath = buildPath(fixture.config.dataDir, "coord", "inboxes", "marlow", "cursors.json");
    exists(cursorsPath).should == true;

    // Post 2 entries to trim the first 2 entries. This shifts marlow's cursor: 2 - 2 = 0.
    // Because *position changed (2 -> 0), saveCursors MUST be called once to persist 0.
    bus.post(room, wren, "m2", null); // trimmed 1, pos becomes 1 -> saved
    bus.post(room, wren, "m3", null); // trimmed 1, pos becomes 0 -> saved

    bus.cursor("marlow", "room:general").should == 0;

    // Check inode of cursors.json
    stat_t stBefore;
    stat(cursorsPath.toStringz, &stBefore).should == 0;

    // Now Marlow is IDLE (does not call read). Cursor remains at 0.
    // We post 10 more messages. Each post trims 1 entry and calls shiftCursors.
    // Since *position is 0, *position < trimmed ? 0 : ... keeps it 0 (*position == original).
    // The disk thrashing guard `if (*position != original)` MUST prevent saveCursors!
    foreach (i; 4..14)
        bus.post(room, wren, "m"~i.to!string, null);

    stat_t stAfter;
    stat(cursorsPath.toStringz, &stAfter).should == 0;

    // The file must NOT have been rewritten! Inode must remain unchanged.
    stAfter.st_ino.should == stBefore.st_ino;
}
