module tests.coord;

import daemon.agent;
import daemon.coord;
import daemon.coord.access;
import daemon.coord.stream;
import tests.common;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import std.array : replicate;
import std.conv : to;
import std.file;
import std.json : JSONValue;
import std.path : buildPath;
import std.string : splitLines;
import std.traits : hasUDA;

private:

string[] texts(Entry[] entries)
{
    string[] ret = new string[0];
    foreach (entry; entries)
        ret ~= entry.text;

    return ret;
}

public:

@Name("Coordination declares module-level HTTP endpoints")
unittest
{
    static foreach (HANDLER; ["rooms", "room", "roomMessages", "roomMembership", "roomAdmins", "messages"])
    {
        hasUDA!(mixin(HANDLER), endpoint).should == true;
        hasUDA!(mixin(HANDLER), route).should == true;
    }
}

@Name("Coordination posts, reads, and advances cursors")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("#General", marlow.name);
    room.name.should == "general";
    bus.getRoom("GENERAL").name.should == "general";
    (bus.getRoom("missing") is null).should == true;
    bus.visibleRooms(wren.name).length.should == 1;

    Entry posted = bus.post(room, wren, "hello", null);
    posted.from.should == "wren";
    posted.room.should == "general";
    texts(bus.readRoom(room, marlow, 50)).should == ["hello"];
    bus.readRoom(room, marlow, 50).length.should == 0;
    bus.post(room, marlow, "mine", null);
    bus.roomEntry(room, marlow)["count"].integer.should == 2;
    bus.roomEntry(room, marlow)["unread"].integer.should == 0;
    bus.roomEntry(room, wren)["unread"].integer.should == 1;
}

@Name("Coordination first read starts with the newest entries")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", wren.name);
    foreach (i; 0 .. 5)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 2)).should == ["m3", "m4"];
    bus.readRoom(room, marlow, 2).length.should == 0;
}

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
    foreach (i; 0 .. MAX_ENTRIES + 1)
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

@Name("Coordination skips malformed log lines")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", marlow.name);
    append(
        buildPath(room.directory, "messages.jsonl"),
        "not json\n"~`{"id":"entry","ts":7,"from":"wren","text":"kept"}`~"\n"
    );

    Bus reloaded = new Bus(fixture.config, fixture.store);
    Entry[] entries = reloaded.readRoom(reloaded.getRoom("general"), marlow, 50);
    entries.length.should == 1;
    entries[0].id.should == "entry";
    entries[0].timestamp.should == 7;
}

@Name("Coordination membership governs visibility and administration")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Profile quill = fixture.store.register("quill", "session-3");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", marlow.name);
    room.owner.should == "marlow";
    room.originalOwner(HUMAN_NAME).should == true;
    room.administrator(wren.name).should == false;
    room.visible(quill.name).should == true;

    room.setInvolved([marlow.name, wren.name]);
    room.visible(quill.name).should == false;
    room.visible(wren.name).should == true;
    bus.visibleRooms(quill.name).length.should == 0;
    room.addAdmin(wren.name);
    room.administrator(wren.name).should == true;
    room.removeAdmin(wren.name);
    room.administrator(wren.name).should == false;

    room.setInvolved(new string[0]);
    room.visible(wren.name).should == false;
    room.visible(marlow.name).should == true;
    room.involveEveryone();
    room.visible(quill.name).should == true;

    Room reloaded = new Bus(fixture.config, fixture.store).getRoom("general");
    reloaded.visible(quill.name).should == true;
    reloaded.admin(wren.name).should == false;
}

@Name("Coordination delivers direct messages and pings once")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", marlow.name);
    bus.direct(marlow, wren, "hi", [marlow, marlow]);
    bus.unreadPings(marlow).length.should == 1;
    bus.unreadPings(wren).length.should == 0;

    Entry[] dms = bus.readDirect(marlow, 50);
    dms.length.should == 1;
    dms[0].to.should == "marlow";
    bus.readDirect(marlow, 50).length.should == 0;
    bus.readPings(marlow, 50).length.should == 1;

    bus.post(room, wren, "work", [marlow, wren]);
    Entry[] pings = bus.readPings(marlow, 50);
    pings.length.should == 1;
    pings[0].room.should == "general";
    bus.unreadPings(marlow).length.should == 0;
}

@Name("Coordination rejects invalid names, duplicates, and symlinked streams")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("general", marlow.name);
    bus.createRoom("general", marlow.name).shouldThrow!Exception();
    bus.createRoom("bad name", marlow.name).shouldThrow!Exception();
    fixture.store.create(HUMAN_NAME).shouldThrow!ProfileConflictException();
    fixture.store.register(HUMAN_NAME, "session-2").shouldThrow!ProfileConflictException();

    string path = buildPath(room.directory, "messages.jsonl");
    string target = buildPath(fixture.root, "target.jsonl");
    write(target, "");
    symlink(target, path);
    bus.post(room, marlow, "hello", null).shouldThrow!Exception();
    readText(target).should == "";
    exists(path).should == true;
}

@Name("Coordination stream rotates on-disk log when line count reaches maxStreamEntries")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_stream.jsonl");
    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 5);

    foreach (i; 0 .. 5)
        stream.append(Entry.create("wren", "e" ~ i.to!string));

    exists(path).should == true;
    exists(path ~ ".1").should == false;
    stream.entries.length.should == 5;

    stream.append(Entry.create("wren", "e5"));
    exists(path ~ ".1").should == true;
    exists(path).should == true;
    stream.entries.length.should == 5;
    stream.since(0).length.should == 5;
    stream.since(0)[0].text.should == "e1";
    stream.since(0)[4].text.should == "e5";

    string rotatedContent = readText(path ~ ".1");
    rotatedContent.splitLines().length.should == 5;

    string activeContent = readText(path);
    activeContent.splitLines().length.should == 1;
}

@Name("Coordination stream rotates on-disk log when file size reaches maxStreamBytes")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_size_stream.jsonl");
    Stream stream = new Stream("test", path, 400, 100);

    string payload = replicate("A", 150);
    foreach (i; 0 .. 5)
        stream.append(Entry.create("wren", payload ~ i.to!string));

    exists(path ~ ".1").should == true;
    (getSize(path ~ ".1") <= 800).should == true;
    (getSize(path) <= 800).should == true;
    stream.entries.length.should == 5;
}

@Name("Coordination stream reconstructs tail window across reload after rotation")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_reload_stream.jsonl");
    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 5);

    foreach (i; 0 .. 7)
        stream.append(Entry.create("wren", "m" ~ i.to!string));

    exists(path ~ ".1").should == true;

    Stream reloaded = new Stream("test", path, 4 * 1024 * 1024, 5);
    reloaded.entries.length.should == 5;
    texts(reloaded.entries).should == ["m2", "m3", "m4", "m5", "m6"];
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

    foreach (i; 1 .. 7)
        bus.post(room, wren, "m" ~ i.to!string, null);

    Entry[] secondRead = bus.readRoom(room, marlow, 50);
    texts(secondRead).should == ["m2", "m3", "m4", "m5", "m6"];
}

@Name("Coordination stream rejects rotation if destination is a symlink")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_symlink_stream.jsonl");
    string rotated = path ~ ".1";
    string target = buildPath(fixture.root, "outside.jsonl");
    write(target, "secret");

    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 2);
    stream.append(Entry.create("wren", "first"));
    stream.append(Entry.create("wren", "second"));

    symlink(target, rotated);
    stream.append(Entry.create("wren", "third")).shouldThrow!Exception();
    readText(target).should == "secret";
}

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

    foreach (i; 0 .. 5)
        bus.post(room, wren, "m" ~ i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1", "m2", "m3", "m4"];
    bus.readRoom(room, marlow, 50).length.should == 0;

    foreach (i; 5 .. 10)
        bus.post(room, wren, "m" ~ i.to!string, null);

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

    foreach (i; 0 .. 3)
        bus.post(room, wren, "m" ~ i.to!string, null);

    bus.readRoom(room, marlow, 50).length.should == 3;

    foreach (i; 3 .. 8)
        bus.post(room, wren, "m" ~ i.to!string, null);

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

    foreach (i; 0 .. 3)
        bus.post(room, wren, "m" ~ i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1", "m2"];
    bus.readRoom(room, marlow, 50).length.should == 0;

    foreach (i; 3 .. 8)
        bus.post(room, wren, "m" ~ i.to!string, null);

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

    foreach (i; 0 .. 2)
        bus.post(room, wren, "m" ~ i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1"];
    texts(bus.readRoom(room, quill, 50)).should == ["m0", "m1"];

    foreach (i; 2 .. 5)
        bus.post(room, wren, "m" ~ i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m2", "m3", "m4"];

    foreach (i; 5 .. 8)
        bus.post(room, wren, "m" ~ i.to!string, null);

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

    foreach (i; 0 .. 2)
        bus.post(room, wren, "m" ~ i.to!string, null);

    texts(bus.readRoom(room, marlow, 50)).should == ["m0", "m1"];

    foreach (i; 2 .. 7)
        bus.post(room, wren, "m" ~ i.to!string, null);

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
    import std.json : JSONType, parseJSON;

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
    foreach (i; 0 .. 5)
        reloaded.post(restored, wren, "m" ~ i.to!string, null);

    // Limit is 2, target has 5 entries. Because cursor was established at 0, should read m0, m1!
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m0", "m1"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m2", "m3"];
    texts(reloaded.readRoom(restored, marlow, 2)).should == ["m4"];
    reloaded.readRoom(restored, marlow, 2).length.should == 0;
}

@Name("Coordination idle reader at cursor 0 does not repeatedly save cursors on stream trim")
unittest
{
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;

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
    auto inodeBefore = stBefore.st_ino;

    // Now Marlow is IDLE (does not call read). Cursor remains at 0.
    // We post 10 more messages. Each post trims 1 entry and calls shiftCursors.
    // Since *position is 0, *position < trimmed ? 0 : ... keeps it 0 (*position == original).
    // The disk thrashing guard `if (*position != original)` MUST prevent saveCursors!
    foreach (i; 4 .. 14)
        bus.post(room, wren, "m" ~ i.to!string, null);

    stat_t stAfter;
    stat(cursorsPath.toStringz, &stAfter).should == 0;
    auto inodeAfter = stAfter.st_ino;

    // The file must NOT have been rewritten! Inode must remain unchanged.
    inodeAfter.should == inodeBefore;
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
    Profile human = Profile(HUMAN_NAME);

    Bus bus = new Bus(fixture.config, fixture.store);
    Room room = bus.createRoom("stress", wren.name);

    // Initial state: human and marlow read empty room -> records cursor 0
    bus.readRoom(room, human, 10).length.should == 0;
    bus.readRoom(room, marlow, 10).length.should == 0;
    bus.hasCursor(HUMAN_NAME, "room:stress").should == true;
    bus.hasCursor("marlow", "room:stress").should == true;
    bus.hasCursor("quill", "room:stress").should == false; // quill has NOT read

    // 10 messages posted in batches
    foreach (i; 0 .. 10)
        bus.post(room, wren, "msg-" ~ i.to!string, null);

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

    reloaded.hasCursor(HUMAN_NAME, "room:stress").should == true;
    texts(reloaded.readRoom(restored, human, 2)).should == ["msg-6", "msg-7"];
    texts(reloaded.readRoom(restored, human, 2)).should == ["msg-8", "msg-9"];
    reloaded.readRoom(restored, human, 2).length.should == 0;
}




