module tests.db.coord;

import daemon.db : Connection;
import daemon.db.profiles : Profiles, StoredProfile;
import daemon.db.rooms : Rooms, StoredRoom;
import daemon.exception : InvalidInputException;
import tests.common : Fixture;

import arsd.sqlite : Sqlite, queryOneColumn, SQLITE_OPEN_READONLY;

import unit_threaded : Name, should, shouldThrow;

import core.thread : Thread;
import std.conv : octal, to;
import std.file : mkdirRecurse, setAttributes;
import std.path : buildPath;

private Sqlite inspect(Connection connection)
    => new Sqlite(connection.path, SQLITE_OPEN_READONLY);

private string[] tableNames(Sqlite raw)
{
    string[] ret;
    foreach (row; raw.query("select name from sqlite_master where type in ('table','trigger') order by name"))
        ret ~= row["name"].toString.idup;
    return ret;
}

private void writeV1(string path)
{
    Sqlite raw = new Sqlite(path);
    raw.query("create table profiles (name text primary key not null check(length(name) between 1 and 64 and "~
        "name glob '[a-z0-9]*' and name not glob '*[^a-z0-9_-]*' and name != 'human'))");
    raw.query("create table session_associations (provider text not null, session_id text not null, "~
        "profile_name text not null references profiles(name) on delete restrict, "~
        "primary key(provider, session_id), unique(profile_name, provider, session_id))");
    raw.query("create table profile_bindings (profile_name text primary key not null "~
        "references profiles(name) on delete restrict, provider text, session_id text, "~
        "unique(provider, session_id), check((provider is null and session_id is null) or "~
        "(provider is not null and session_id is not null)), foreign key(profile_name, provider, session_id) "~
        "references session_associations(profile_name, provider, session_id) on delete restrict)");
    raw.query("create table imports (domain text primary key not null, source_version integer not null, source text not null)");
    raw.query("insert into profiles values ('marlow'), ('wren')");
    raw.query("insert into session_associations values ('devin', 'session-1', 'marlow'), ('devin', 'session-2', 'marlow')");
    raw.query("insert into profile_bindings values ('marlow', 'devin', 'session-1'), ('wren', null, null)");
    raw.query("insert into imports values ('profiles', 1, 'v1-fixture')");
    raw.query("pragma application_id = 0x4155544F");
    raw.query("pragma user_version = 1");
    destroy(raw);
    setAttributes(path, octal!"600");
}

@Name("A fresh database opens at schema version two and reopens cleanly")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    string[] names = tableNames(inspect(connection));
    (names.length >= 8).should == true;
    connection.close();

    connection = new Connection(fixture.config.dataDir);
    new Profiles(connection).create("marlow");
}

@Name("Version one databases upgrade preserving rows and deriving actors")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    mkdirRecurse(fixture.config.dataDir);
    writeV1(buildPath(fixture.config.dataDir, "autonom.db"));

    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();

    StoredProfile marlow = new Profiles(connection).get("marlow").get;
    marlow.current.isNull.should == false;
    new Profiles(connection).get("wren").get.current.isNull.should == true;

    Sqlite raw = inspect(connection);
    scope(exit)
        destroy(raw);
    raw.queryOneColumn!long("select source_version from imports where domain = 'profiles'").should == 1;
    raw.queryOneColumn!long("select count(*) from actors where profile_name is not null").should == 2;
    raw.queryOneColumn!long("select count(*) from actors where name = 'human' and profile_name is null").should == 1;

    new Profiles(connection).create("quill");
    destroy(raw);
    raw = inspect(connection);
    raw.queryOneColumn!long("select count(*) from actors where name = 'quill'").should == 1;
    destroy(raw);
}

@Name("A colliding table fails the upgrade without publishing partial coordination schema")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    mkdirRecurse(fixture.config.dataDir);
    string path = buildPath(fixture.config.dataDir, "autonom.db");
    writeV1(path);
    Sqlite raw = new Sqlite(path);
    raw.query("create table rooms (junk text)");
    destroy(raw);
    setAttributes(path, octal!"600");

    new Connection(fixture.config.dataDir).shouldThrow!Exception();
    raw = new Sqlite(path, SQLITE_OPEN_READONLY);
    raw.queryOneColumn!int("pragma user_version").should == 1;
    raw.queryOneColumn!long("select count(*) from profiles").should == 2;
    bool hasActors;
    foreach (name; tableNames(raw))
        hasActors = hasActors || name == "actors" || name == "profile_actor";
    hasActors.should == false;
    destroy(raw);

    raw = new Sqlite(path);
    raw.query("drop table rooms");
    destroy(raw);
    setAttributes(path, octal!"600");
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    inspect(connection).queryOneColumn!int("pragma user_version").should == 2;
}

@Name("Rooms store canonical snapshots with human ownership and rollback")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    new Profiles(connection).create("marlow");
    new Profiles(connection).create("wren");
    Rooms rooms = new Rooms(connection);

    StoredRoom general;
    general.name = "general";
    general.owner = "human";
    general.admins = ["marlow"];
    rooms.create(general);
    StoredRoom fetched = rooms.get("general").get;
    fetched.owner.should == "human";
    fetched.admins.should == ["marlow"];
    fetched.restricted.should == false;
    fetched.involved.length.should == 0;

    StoredRoom guarded = general;
    guarded.name = "guarded";
    guarded.restricted = true;
    guarded.involved = ["wren"];
    rooms.create(guarded);
    rooms.get("guarded").get.involved.should == ["wren"];
    rooms.list().length.should == 2;

    StoredRoom bad = general;
    bad.name = "Upper Case";
    rooms.create(bad).shouldThrow!Exception();
    bad.name = "broken";
    bad.owner = "ghost";
    rooms.create(bad).shouldThrow!Exception();
    rooms.get("broken").isNull.should == true;
    bad.owner = "human";
    bad.restricted = false;
    bad.involved = ["wren"];
    rooms.create(bad).shouldThrow!InvalidInputException();

    StoredRoom renamed = general;
    renamed.owner = "marlow";
    rooms.update(renamed).shouldThrow!Exception();
    renamed.name = "missing";
    renamed.owner = "human";
    rooms.update(renamed).shouldThrow!Exception();
    renamed = rooms.get("general").get;
    renamed.restricted = true;
    renamed.involved = ["ghost"];
    rooms.update(renamed).shouldThrow!Exception();
    rooms.get("general").get.restricted.should == false;

    renamed.involved = ["wren"];
    rooms.update(renamed);
    rooms.get("general").get.involved.should == ["wren"];

    rooms.remove("missing");
    rooms.remove("guarded");
    rooms.list().length.should == 1;
    Sqlite raw = inspect(connection);
    raw.queryOneColumn!long("select count(*) from streams where room = 'guarded'").should == 0;
    raw.queryOneColumn!long("select count(*) from streams where room = 'general'").should == 1;
    destroy(raw);
}
