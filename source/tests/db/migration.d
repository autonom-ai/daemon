module tests.db.migration;

import daemon.db : Connection;
import daemon.db.legacyprofiles : importProfiles;
import daemon.db.profiles : Profiles;
import daemon.exception : ConflictException;
import daemon.interop.session : SessionKey;
import tests.common : Fixture;

import arsd.sqlite : Sqlite;
import unit_threaded : Name, should, shouldThrow;

import std.file : exists, isSymlink, mkdir, mkdirRecurse, readText, remove, symlink, write;
import std.path : buildPath;

@Name("Version one profile import is atomic, idempotent, and leaves source bytes unchanged")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    fixture.store.register("marlow", "first");
    fixture.store.register("marlow", "second");
    fixture.store.create("wren");
    string source = buildPath(fixture.store.directory, "state.json");
    string before = readText(source);
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    importProfiles(connection, fixture.store.directory).should == true;
    importProfiles(connection, fixture.store.directory).should == false;
    Profiles profiles = new Profiles(connection);
    profiles.list().length.should == 2;
    profiles.get("marlow").get.current.get.id.should == "second";
    profiles.get("wren").get.current.isNull.should == true;
    profiles.history("marlow").length.should == 2;
    profiles.bind("marlow", SessionKey("devin", "third"));
    readText(source).should == before;
    connection.close();

    connection = new Connection(fixture.config.dataDir);
    importProfiles(connection, fixture.store.directory).should == false;
    profiles = new Profiles(connection);
    profiles.history("marlow").length.should == 3;
    profiles.get("marlow").get.current.get.id.should == "third";
    readText(source).should == before;
}

@Name("Legacy per-profile import does not create or rewrite file-store state")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    string directory = fixture.store.directory;
    mkdirRecurse(buildPath(directory, "marlow"));
    string assignments = buildPath(directory, "sessions.json");
    string binding = buildPath(directory, "marlow", "session.json");
    write(assignments, `{"first":"MARLOW","second":"marlow"}`);
    write(binding, `{"session_id":"second"}`);
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    importProfiles(connection, directory).should == true;
    Profiles profiles = new Profiles(connection);
    profiles.get("marlow").get.current.get.id.should == "second";
    profiles.history("marlow").length.should == 2;
    readText(assignments).should == `{"first":"MARLOW","second":"marlow"}`;
    readText(binding).should == `{"session_id":"second"}`;
    exists(buildPath(directory, "state.json")).should == false;
}

@Name("Malformed, duplicate, unsupported, or conflicting profile imports publish nothing")
unittest
{
    foreach (content; [
        `{`,
        `{"version":2,"assignments":{},"bindings":{}}`,
        `{"version":1,"assignments":[],"bindings":{}}`,
        `{"version":1,"assignments":{"bad id":"marlow"},"bindings":{"marlow":null}}`,
        `{"version":1,"assignments":{"first":"missing"},"bindings":{"marlow":null}}`,
        `{"version":1,"assignments":{"first":"marlow"},"bindings":{"wren":"first"}}`,
        `{"version":1,"assignments":{},"bindings":{"human":null}}`,
        `{"version":1,"version":1,"assignments":{},"bindings":{}}`,
        `{"version":1,"assignments":{"first":"marlow","f\u0069rst":"wren"},"bindings":{"marlow":null}}`
    ])
    {
        Fixture fixture = Fixture.create();
        scope(exit)
            fixture.close();
        mkdirRecurse(buildPath(fixture.store.directory, "marlow"));
        mkdirRecurse(buildPath(fixture.store.directory, "wren"));
        string source = buildPath(fixture.store.directory, "state.json");
        write(source, content);
        Connection connection = new Connection(fixture.config.dataDir);
        scope(exit)
            connection.close();
        importProfiles(connection, fixture.store.directory).shouldThrow!Exception();
        new Profiles(connection).list().length.should == 0;
        readText(source).should == content;
        write(source, `{"version":1,"assignments":{"first":"marlow"},"bindings":{"marlow":"first"}}`);
        importProfiles(connection, fixture.store.directory).should == true;
    }
}

@Name("Interrupted profile import rolls back rows and its completion marker together")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    fixture.store.register("marlow", "first");
    string source = buildPath(fixture.store.directory, "state.json");
    string before = readText(source);
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    Sqlite fault = new Sqlite(connection.path);
    fault.query("create trigger fail_import before insert on session_associations "~
        "begin select raise(abort, 'fixture failure'); end");
    destroy(fault);
    importProfiles(connection, fixture.store.directory).shouldThrow!Exception();
    new Profiles(connection).list().length.should == 0;
    readText(source).should == before;
    fault = new Sqlite(connection.path);
    fault.query("drop trigger fail_import");
    destroy(fault);
    importProfiles(connection, fixture.store.directory).should == true;
}

@Name("Profile import refuses a mixed destination or a symlinked source")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string source = buildPath(fixture.store.directory, "state.json");
    string target = buildPath(fixture.root, "source.json");
    write(target, `{"version":1,"assignments":{},"bindings":{}}`);
    symlink(target, source);
    importProfiles(connection, fixture.store.directory).shouldThrow!Exception();
    readText(target).should == `{"version":1,"assignments":{},"bindings":{}}`;
    Profiles profiles = new Profiles(connection);
    profiles.create("existing");
    importProfiles(connection, fixture.store.directory).shouldThrow!ConflictException();
    profiles.list().length.should == 1;
}

@Name("Profile import refuses a dangling source-directory symlink until it is repaired")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string target = buildPath(fixture.root, "missing-source");
    string source = buildPath(fixture.root, "legacy");
    symlink(target, source);
    assertRejectedDanglingSource(connection, source, source, target);
    remove(source);
    mkdir(source);
    importProfiles(connection, source).should == true;
}

@Name("Profile import refuses a dangling state.json symlink until it is repaired")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string source = buildPath(fixture.root, "legacy");
    mkdir(source);
    string target = buildPath(fixture.root, "missing-state");
    string state = buildPath(source, "state.json");
    symlink(target, state);
    assertRejectedDanglingSource(connection, source, state, target);
    remove(state);
    write(state, `{"version":1,"assignments":{},"bindings":{}}`);
    importProfiles(connection, source).should == true;
}

@Name("Profile import refuses a dangling sessions.json symlink until it is repaired")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string source = buildPath(fixture.root, "legacy");
    mkdir(source);
    string target = buildPath(fixture.root, "missing-sessions");
    string sessions = buildPath(source, "sessions.json");
    symlink(target, sessions);
    assertRejectedDanglingSource(connection, source, sessions, target);
    remove(sessions);
    write(sessions, `{}`);
    importProfiles(connection, source).should == true;
}

@Name("Profile import refuses a dangling session.json symlink until it is repaired")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string source = buildPath(fixture.root, "legacy");
    mkdirRecurse(buildPath(source, "marlow"));
    write(buildPath(source, "sessions.json"), `{"first":"marlow"}`);
    string target = buildPath(fixture.root, "missing-session");
    string session = buildPath(source, "marlow", "session.json");
    symlink(target, session);
    assertRejectedDanglingSource(connection, source, session, target);
    remove(session);
    write(session, `{"session_id":"first"}`);
    importProfiles(connection, source).should == true;
    new Profiles(connection).get("marlow").get.current.get.id.should == "first";
}

@Name("Profile import accepts a genuinely missing source once")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string missing = buildPath(fixture.root, "absent-source");
    importProfiles(connection, missing).should == true;
    importProfiles(connection, missing).should == false;
}

@Name("Profile import rejects legacy sources with the wrong path type")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string fileRoot = buildPath(fixture.root, "file-source");
    write(fileRoot, "not a directory");
    importProfiles(connection, fileRoot).shouldThrow!Exception();
    string dirSource = buildPath(fixture.root, "legacy");
    mkdirRecurse(buildPath(dirSource, "state.json"));
    importProfiles(connection, dirSource).shouldThrow!Exception();
    new Profiles(connection).list().length.should == 0;
    Sqlite check = new Sqlite(connection.path);
    scope(exit)
        destroy(check);
    check.query("select domain from imports where domain = ?", "profiles").empty.should == true;
}

private void assertRejectedDanglingSource(Connection connection, string source, string link, string target)
{
    importProfiles(connection, source).shouldThrow!Exception();
    new Profiles(connection).list().length.should == 0;
    Sqlite check = new Sqlite(connection.path);
    scope(exit)
        destroy(check);
    check.query("select domain from imports where domain = ?", "profiles").empty.should == true;
    isSymlink(link).should == true;
    exists(target).should == false;
}
