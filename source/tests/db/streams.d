module tests.db.streams;

import daemon.coord.entry : Entry;
import daemon.db : Connection;
import daemon.db.cursors : Cursors;
import daemon.db.profiles : Profiles;
import daemon.db.rooms : Rooms, StoredRoom;
import daemon.db.streams : Streams, StoredEntry;
import tests.common : Fixture;

import arsd.sqlite : Sqlite;
import unit_threaded : Name, should, shouldThrow;

import core.thread : Thread;

import std.array : replicate;
import std.conv : to;

private Entry entry(string text, string sender = "marlow", string id = null)
{
    Entry ret = Entry.create(sender, text);
    if (id.length)
        ret.id = id;
    return ret;
}

private Entry fixedEntry(string text, string id, string sender = "marlow")
{
    Entry ret;
    ret.id = id;
    ret.timestamp = 1_700_000_000_000;
    ret.from = sender;
    ret.text = text;
    return ret;
}

private long encodedBytes(Entry entry)
    => cast(long)entry.toJSON().toString().length + 1;

private Fixture prepare(ref Connection connection, ref Streams streams, ref Cursors cursors)
{
    Fixture fixture = Fixture.create();
    connection = new Connection(fixture.config.dataDir);
    new Profiles(connection).create("marlow");
    new Profiles(connection).create("wren");
    streams = new Streams(connection, 4, 512);
    cursors = new Cursors(connection);
    return fixture;
}

@Name("Streams append bounded ordered entries and preserve them across reopen")
unittest
{
    Connection connection;
    Streams streams;
    Cursors cursors;
    Fixture fixture = prepare(connection, streams, cursors);
    scope(exit)
        fixture.close();
    scope(exit)
        connection.close();

    streams.ensureInbox("marlow");
    streams.ensureInbox("marlow");
    streams.ensureInbox("marlow", true);
    streams.ensureInbox("human");
    streams.ensureInbox("ghost").shouldThrow!Exception();
    Entry first = entry("first");
    Entry second = entry("quoted ' text", "wren");
    second.to = "marlow";
    second.room = "general";
    long one = streams.append("dm:marlow", first);
    long two = streams.append("dm:marlow", second);
    (two - one).should == 1;
    streams.append("dm:marlow", entry("third")).should == 3;
    Entry humanEntry = entry("human inbox", "human");
    streams.append("dm:human", humanEntry).should == 1;
    Rooms rooms = new Rooms(connection);
    StoredRoom room;
    room.name = "history-room";
    room.owner = "marlow";
    room.restricted = true;
    room.admins = ["wren"];
    room.involved = ["wren"];
    rooms.create(room);
    Entry roomEntry = Entry.create("wren", "room history", null, room.name);
    streams.append("room:"~room.name, roomEntry).should == 1;
    Cursors cursors = new Cursors(connection);
    cursors.advance("marlow", "dm:marlow", 1);
    cursors.advance("wren", "dm:marlow", 2);
    cursors.advance("human", "dm:marlow", 0);
    cursors.advance("human", "room:"~room.name, 1);
    connection.close();

    connection = new Connection(fixture.config.dataDir);
    streams = new Streams(connection, 4, 512);
    cursors = new Cursors(connection);
    rooms = new Rooms(connection);
    StoredEntry[] all = streams.read("dm:marlow");
    all.length.should == 3;
    all[0].sequence.should == 1;
    all[0].entry.id.should == first.id;
    all[0].entry.timestamp.should == first.timestamp;
    all[1].entry.to.should == "marlow";
    all[1].entry.room.should == "general";
    all[1].entry.text.should == "quoted ' text";
    all[1].entry.from.should == "wren";
    streams.read("dm:marlow", 2)[0].sequence.should == 3;
    streams.read("dm:human")[0].entry.id.should == humanEntry.id;
    streams.read("room:history-room")[0].entry.id.should == roomEntry.id;
    streams.read("room:history-room")[0].entry.room.should == "history-room";
    rooms.get("history-room").get.owner.should == "marlow";
    rooms.get("history-room").get.admins.should == ["wren"];
    rooms.get("history-room").get.involved.should == ["wren"];
    rooms.get("history-room").get.restricted.should == true;
    cursors.get("marlow", "dm:marlow").get.should == 1;
    cursors.get("wren", "dm:marlow").get.should == 2;
    cursors.get("human", "dm:marlow").get.should == 0;
    cursors.get("human", "room:history-room").get.should == 1;
    new Profiles(connection).get("human").isNull.should == true;

    streams.append("ghost", first).shouldThrow!Exception();
    streams.append("dm:marlow", entry("dupe", "marlow", first.id)).shouldThrow!Exception();
    streams.append("dm:marlow", entry("ghost", "nobody")).shouldThrow!Exception();
    Entry huge = entry("x".replicate(600));
    streams.append("dm:marlow", huge).shouldThrow!Exception();
    streams.read("dm:marlow").length.should == 3;

    foreach (i; 0..3)
        streams.append("dm:marlow", entry("overflow-"~i.to!string));
    StoredEntry[] retained = streams.read("dm:marlow");
    retained.length.should == 4;
    retained[0].entry.text.should == "third";
    retained[$-1].sequence.should == 6;
    streams.read("dm:marlow", -1).shouldThrow!Exception();
    streams.read("dm:marlow", 0, 0).length.should == 0;
    streams.read("missing").length.should == 0;
}

@Name("Stream byte retention uses exact encoded suffix bounds and failed appends consume no sequence")
unittest
{
    Connection connection;
    Streams streams;
    Cursors cursors;
    Fixture fixture = prepare(connection, streams, cursors);
    scope(exit)
        fixture.close();
    scope(exit)
        connection.close();

    Entry first = fixedEntry("quote \"line\nslash\\", "entry-000000000000000000000000000001");
    Entry second = fixedEntry("quote \"line\nslash\\", "entry-000000000000000000000000000002");
    Entry third = fixedEntry("quote \"line\nslash\\", "entry-000000000000000000000000000003");
    Entry fourth = fixedEntry("quote \"line\nslash\\", "entry-000000000000000000000000000004");
    long cost = encodedBytes(first);
    encodedBytes(second).should == cost;
    encodedBytes(third).should == cost;
    encodedBytes(fourth).should == cost;
    streams.ensureInbox("marlow");
    streams.ensureInbox("wren");
    Streams exact = new Streams(connection, 20, cast(size_t)(2 * cost));
    exact.append("dm:marlow", first).should == 1;
    exact.append("dm:marlow", second).should == 2;
    exact.read("dm:marlow").length.should == 2;
    exact.append("dm:marlow", third).should == 3;
    StoredEntry[] retained = exact.read("dm:marlow");
    retained.length.should == 2;
    retained[0].entry.id.should == second.id;
    retained[0].sequence.should == 2;
    retained[1].entry.id.should == third.id;
    retained[1].sequence.should == 3;

    Entry duplicate = fixedEntry("duplicate", third.id);
    exact.append("dm:marlow", duplicate).shouldThrow!Exception();
    exact.append("dm:marlow", fixedEntry("unknown sender", "entry-unknown", "ghost"))
        .shouldThrow!Exception();
    exact.append("dm:marlow", fixedEntry("empty id", "")).shouldThrow!Exception();
    exact.append("dm:marlow", fixedEntry("x".replicate(4096), "entry-oversized"))
        .shouldThrow!Exception();
    retained = exact.read("dm:marlow");
    retained.length.should == 2;
    retained[0].sequence.should == 2;
    retained[0].entry.id.should == second.id;
    retained[1].sequence.should == 3;
    retained[1].entry.id.should == third.id;
    exact.append("dm:marlow", fourth).should == 4;

    Streams below = new Streams(connection, 20, cast(size_t)(2 * cost - 1));
    below.append("dm:wren", first).should == 1;
    below.append("dm:wren", second).should == 2;
    StoredEntry[] one = below.read("dm:wren");
    one.length.should == 1;
    one[0].sequence.should == 2;
    one[0].entry.id.should == second.id;
}

@Name("Stream bounds accept long.max without overflow and reject sequence exhaustion")
unittest
{
    Connection connection;
    Streams streams;
    Cursors cursors;
    Fixture fixture = prepare(connection, streams, cursors);
    scope(exit)
        fixture.close();
    scope(exit)
        connection.close();

    new Streams(connection, 0, 1).shouldThrow!Exception();
    new Streams(connection, 1, 0).shouldThrow!Exception();
    new Streams(connection, cast(size_t)long.max + 1, 512).shouldThrow!Exception();
    streams.ensureInbox("marlow");
    Streams hugeBound = new Streams(connection, cast(size_t)long.max, 512);
    hugeBound.append("dm:marlow", entry("small")).should == 1;
    hugeBound.read("dm:marlow").length.should == 1;

    Sqlite raw = new Sqlite(connection.path);
    raw.query("update streams set next_sequence = ? where name = 'dm:marlow'", long.max);
    destroy(raw);
    hugeBound.append("dm:marlow", entry("exhausted")).shouldThrow!Exception();
    hugeBound.read("dm:marlow").length.should == 1;
}

@Name("Room stream reads enforce ownership even at a zero limit")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    new Profiles(connection).create("marlow");
    Streams streams = new Streams(connection, 4, 512);
    streams.ensureInbox("marlow");
    Rooms rooms = new Rooms(connection);
    StoredRoom room;
    room.name = "worker";
    room.owner = "marlow";
    rooms.create(room);
    Cursors cursors = new Cursors(connection);

    size_t rejected;
    Thread worker = new Thread({
        try
            rooms.list();
        catch (Exception)
            rejected++;
        try
            streams.read("dm:marlow", 0, 0);
        catch (Exception)
            rejected++;
        try
            cursors.get("marlow", "dm:marlow");
        catch (Exception)
            rejected++;
    });
    worker.start();
    worker.join();
    rejected.should == 3;

    connection.close();
    rooms.list().shouldThrow!Exception();
    streams.read("dm:marlow", 0, 0).shouldThrow!Exception();
    cursors.get("marlow", "dm:marlow").shouldThrow!Exception();
}

@Name("Stream cursors advance monotonically per actor and survive retention")
unittest
{
    Connection connection;
    Streams streams;
    Cursors cursors;
    Fixture fixture = prepare(connection, streams, cursors);
    scope(exit)
        fixture.close();
    scope(exit)
        connection.close();

    streams.ensureInbox("marlow");
    streams.append("dm:marlow", entry("a"));
    streams.append("dm:marlow", entry("b"));
    streams.append("dm:marlow", entry("c"));

    cursors.get("marlow", "dm:marlow").isNull.should == true;
    cursors.get("human", "dm:marlow").isNull.should == true;
    cursors.advance("marlow", "dm:marlow", 0);
    cursors.get("marlow", "dm:marlow").get.should == 0;
    cursors.get("human", "dm:marlow").isNull.should == true;
    cursors.advance("marlow", "dm:marlow", 2);
    cursors.advance("marlow", "dm:marlow", 1);
    cursors.get("marlow", "dm:marlow").get.should == 2;
    cursors.advance("marlow", "dm:marlow", -1).shouldThrow!Exception();
    cursors.advance("marlow", "dm:marlow", 4).shouldThrow!Exception();
    cursors.advance("ghost", "dm:marlow", 1).shouldThrow!Exception();
    cursors.advance("marlow", "ghost", 1).shouldThrow!Exception();
    cursors.get("marlow", "dm:marlow").get.should == 2;

    foreach (i; 0..3)
        streams.append("dm:marlow", entry("next-"~i.to!string));
    StoredEntry[] fresh = streams.read("dm:marlow", cursors.get("marlow", "dm:marlow").get);
    fresh.length.should == 4;
    fresh[0].entry.text.should == "c";
}

@Name("Room deletion removes only its stream, messages, and cursor")
unittest
{
    Connection connection;
    Streams streams;
    Cursors cursors;
    Fixture fixture = prepare(connection, streams, cursors);
    scope(exit)
        fixture.close();
    scope(exit)
        connection.close();

    Rooms rooms = new Rooms(connection);
    foreach (name; ["alpha", "beta"])
    {
        StoredRoom room;
        room.name = name;
        room.owner = "marlow";
        rooms.create(room);
    }
    streams.append("room:alpha", entry("one"));
    streams.append("room:beta", entry("two"));
    cursors.advance("marlow", "room:alpha", 1);
    cursors.advance("marlow", "room:beta", 1);

    rooms.remove("alpha");
    streams.read("room:alpha").length.should == 0;
    streams.read("room:beta").length.should == 1;
    cursors.get("marlow", "room:alpha").isNull.should == true;
    cursors.get("marlow", "room:beta").get.should == 1;
    streams.append("room:alpha", entry("dead")).shouldThrow!Exception();
}
