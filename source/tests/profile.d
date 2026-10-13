module tests.profile;

import daemon.agent;
import daemon.agent.profile;
import daemon.agent.store;
import daemon.interop;
import tests.common;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_UN;
import std.array : replicate;
import std.conv : octal;
import std.file;
import std.json : parseJSON;
import std.path : buildPath;
import std.stdio : File;
import std.traits : hasUDA;

@Name("Profile declares module-level HTTP endpoints")
unittest
{
    static foreach (HANDLER; ["profiles", "getProfile", "profileSession"])
    {
        hasUDA!(mixin(HANDLER), endpoint).should == true;
        hasUDA!(mixin(HANDLER), route).should == true;
    }
}

@Name("Profile creates canonical names and directories without identity files")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile profile = fixture.store.create("Marlow");
    static assert(!__traits(compiles, profile.session = fixture.bridge.session("session-1")));
    profile.name.should == "marlow";
    (profile.session is null).should == true;
    fixture.store.list().length.should == 1;
    exists(buildPath(fixture.store.directory, "marlow")).should == true;
    exists(buildPath(fixture.store.directory, "marlow", "identity.md")).should == false;
    fixture.store.create("MARLOW").shouldThrow!ProfileConflictException();
}

@Name("Profile imports legacy mappings once without modifying their files")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    mkdirRecurse(buildPath(fixture.store.directory, "marlow"));
    string assignments = buildPath(fixture.store.directory, "sessions.json");
    string binding = buildPath(fixture.store.directory, "marlow", "session.json");
    write(assignments, `{"session-1":"marlow"}`);
    write(binding, `{"session_id":"session-1"}`);
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-1";
    store.register("marlow", "session-2");
    readText(assignments).should == `{"session-1":"marlow"}`;
    readText(binding).should == `{"session_id":"session-1"}`;
    store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-2";
}

@Name("Profile failed persistence leaves bindings and assignments unchanged")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    string path = buildPath(fixture.store.directory, "state.json");
    string target = buildPath(fixture.root, "target.json");
    write(target, "{}");
    if (exists(path))
        remove(path);

    symlink(target, path);
    fixture.store.register("marlow", "session-2").shouldThrow!Exception();
    fixture.store.get("marlow").session.id.should == "session-1";
    (fixture.store.profileFor("session-2") is null).should == true;
    readText(target).should == "{}";
}

@Name("Profile registration persists across instances")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile profile = fixture.store.register("Marlow", "session-1");
    profile.session.id.should == "session-1";
    (fixture.store.get("MARLOW").session is profile.session).should == true;
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-1";
    store.profileFor("session-1").name.should == "marlow";
}

@Name("Profile owns session IDs independently of reused request buffers")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    char[] buffer = "session-1".dup;
    Session session = fixture.store.register("marlow", cast(string)buffer).session;
    buffer[] = 'X';
    session.id.should == "session-1";
    (fixture.store.get("marlow").session is session).should == true;
}

@Name("Profile rejects invalid session IDs without corrupting storage")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("marlow", "../escape").shouldThrow!Exception();
    fixture.store.get("marlow").session.id.should == "session-1";
    fixture.store.register("wren", "invalid id").shouldThrow!Exception();
    (fixture.store.get("wren") is null).should == true;
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-1";
}

@Name("Profile persists session bindings and assignments")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    parseJSON(readText(buildPath(fixture.store.directory, "state.json")))["assignments"]["session-1"].str.should ==
        "marlow";
    parseJSON(readText(buildPath(fixture.store.directory, "state.json")))["bindings"]["marlow"].str.should ==
        "session-1";
}

@Name("Profile keeps session links permanent across rebinding")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("marlow", "session-2");
    fixture.store.get("marlow").session.id.should == "session-2";
    (fixture.store.profileFor("session-1") is null).should == true;
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflictException();
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-2";
    (store.profileFor("session-1") is null).should == true;
    store.register("wren", "session-1").shouldThrow!ProfileConflictException();
}

@Name("Profile prevents duplicate session ownership")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflictException();
    (fixture.store.get("wren") is null).should == true;
}

@Name("Profile locks rebinding while its session is active")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, "session-1.lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }

    flock(lock.fileno, LOCK_EX).should == 0;
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflictException();
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflictException();
    flock(lock.fileno, LOCK_UN).should == 0;
    lock.close();
    fixture.store.register("marlow", "session-2").session.id.should == "session-2";
}

@Name("Profile rejects names that can escape storage")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (name; [
        "",
        "../escape",
        "white space",
        "-name",
        "a".replicate(65)
    ])
        fixture.store.create(name).shouldThrow!Exception();

    fixture.store.list().length.should == 0;
}

@Name("Profile clears bindings when sessions are removed")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    write(fixture.config.devinCommand, "#!/bin/sh\nexit 0\n");
    setAttributes(fixture.config.devinCommand, octal!"700");
    fixture.store.register("marlow", "session-1");
    fixture.bridge.session("session-1").remove();
    fixture.store.unlinkSession("session-1");
    (fixture.store.get("marlow").session is null).should == true;
    (fixture.store.profileFor("session-1") is null).should == true;
    exists(buildPath(fixture.store.directory, "marlow", "session.json")).should == false;
    parseJSON(readText(buildPath(fixture.store.directory, "state.json")))["assignments"].object.length.should == 0;
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    (store.get("marlow").session is null).should == true;
}

@Name("Profile rejects corrupt storage without overwriting it")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.store.directory, "sessions.json");
    foreach (content; [
        "{",
        "[]",
        `{"session-1":7}`,
        `{"session-1":"../escape"}`,
        `{"":"marlow"}`
    ])
    {
        write(path, content);
        new ProfileStore(fixture.config, fixture.bridge).shouldThrow!Exception();
        readText(path).should == content;
    }

    remove(path);
    mkdirRecurse(buildPath(fixture.store.directory, "marlow"));
    path = buildPath(fixture.store.directory, "marlow", "session.json");
    foreach (content; [
        "{",
        "[]",
        `{"session_id":7}`,
        `{"session_id":"../escape"}`
    ])
    {
        write(path, content);
        new ProfileStore(fixture.config, fixture.bridge).shouldThrow!Exception();
        readText(path).should == content;
    }
}

@Name("Profile rejects symlinked storage and keeps private permissions")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    string path = buildPath(fixture.store.directory, "state.json");
    (getAttributes(path) & octal!"777").should == octal!"600";
    string target = buildPath(fixture.root, "target.json");
    write(target, "{}");
    remove(path);
    symlink(target, path);
    new ProfileStore(fixture.config, fixture.bridge).shouldThrow!Exception();
    readText(target).should == "{}";
}
