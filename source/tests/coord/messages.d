module tests.coord.messages;

import daemon.agent : Profile;
import daemon.coord : Bus, Entry, Room;
import tests.common : Fixture;
import tests.coord.common : texts;

import unit_threaded : Name, should;

import std.conv : to;
import std.file : append;
import std.path : buildPath;

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
    foreach (i; 0..5)
        bus.post(room, wren, "m"~i.to!string, null);

    texts(bus.readRoom(room, marlow, 2)).should == ["m3", "m4"];
    bus.readRoom(room, marlow, 2).length.should == 0;
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
