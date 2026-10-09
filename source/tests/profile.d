module tests.profile;

import autonom.agent.profile : Profile, getProfile;
import autonom.agent.store : ProfileConflict, ProfileStore, profileSession, profiles;
import autonom.interop : Session;
import tests.common : Fixture;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import core.sys.linux.sys.file : flock, LOCK_EX;
import std.array : replicate;
import std.conv : octal;
import std.file : exists, getAttributes, mkdirRecurse, readText, remove, setAttributes, symlink, write;
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
    profile.name.should == "marlow";
    (profile.session is null).should == true;
    fixture.store.list().length.should == 1;
    exists(buildPath(fixture.store.directory, "marlow")).should == true;
    exists(buildPath(fixture.store.directory, "marlow", "identity.md")).should == false;
    fixture.store.create("MARLOW").shouldThrow!ProfileConflict();
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
    parseJSON(readText(buildPath(fixture.store.directory, "sessions.json")))["session-1"].str.should == "marlow";
    parseJSON(readText(buildPath(fixture.store.directory, "marlow", "session.json")))["session_id"].str.should ==
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
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflict();
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-2";
    (store.profileFor("session-1") is null).should == true;
    store.register("wren", "session-1").shouldThrow!ProfileConflict();
}

@Name("Profile prevents duplicate session ownership")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflict();
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
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflict();
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflict();
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
    fixture.store.removeSession("session-1");
    (fixture.store.get("marlow").session is null).should == true;
    (fixture.store.profileFor("session-1") is null).should == true;
    exists(buildPath(fixture.store.directory, "marlow", "session.json")).should == false;
    parseJSON(readText(buildPath(fixture.store.directory, "sessions.json"))).object.length.should == 0;
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
    string path = buildPath(fixture.store.directory, "sessions.json");
    (getAttributes(path) & octal!"777").should == octal!"600";
    string target = buildPath(fixture.root, "target.json");
    write(target, "{}");
    remove(path);
    symlink(target, path);
    new ProfileStore(fixture.config, fixture.bridge).shouldThrow!Exception();
    readText(target).should == "{}";
}
