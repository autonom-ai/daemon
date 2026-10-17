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


