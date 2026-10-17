module tests.coord.rooms;

import daemon.agent : Profile, ProfileConflictException, humanName;
import daemon.coord : Bus, Room;
import tests.common : Fixture;

import unit_threaded : Name, should, shouldThrow;

import std.file : exists, write, readText, symlink;
import std.path : buildPath;

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
    room.originalOwner(humanName).should == true;
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
    fixture.store.create(humanName).shouldThrow!ProfileConflictException();
    fixture.store.register(humanName, "session-2").shouldThrow!ProfileConflictException();

    string path = buildPath(room.directory, "messages.jsonl");
    string target = buildPath(fixture.root, "target.jsonl");
    write(target, "");
    symlink(target, path);
    bus.post(room, marlow, "hello", null).shouldThrow!Exception();
    readText(target).should == "";
    exists(path).should == true;
}
