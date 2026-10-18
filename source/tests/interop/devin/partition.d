module tests.interop.devin.partition;

import daemon.interop.devin.catalog : Catalog;
import tests.common : Fixture;
import tests.interop.devin.common : database;

import arsd.sqlite : Sqlite;
import unit_threaded : Name, should;

import core.sys.linux.sys.file : flock, LOCK_EX;
import std.file : mkdirRecurse;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : File;

@Name("Catalog merges stores with partition ownership taking precedence over duplicate IDs")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Sqlite local = database(fixture);
    scope(exit)
        destroy(local);

    string directory = buildPath(fixture.root, "partition");
    mkdirRecurse(directory);
    string managed = buildPath(directory, "sessions.db");
    local.query("vacuum into ?", managed);
    local.query("insert into sessions select 'local-only', model, working_directory, title, agent_mode, "~
        "backend_type, created_at, last_activity_at, hidden, workspace_dirs, main_chain_id, metadata from sessions");
    Sqlite partition = new Sqlite(managed);
    scope(exit)
        destroy(partition);

    partition.query("update sessions set model = 'partition-model'");
    Catalog catalog = new Catalog(managed, fixture.config.sessionDatabase, fixture.config.sessionLockDir);
    catalog.list().length.should == 2;
    catalog.metadata("session-one").model.should == "partition-model";
    catalog.metadata("local-only").model.should == "swe-2-medium";
    catalog.databaseFor("session-one").should == managed;
    catalog.databaseFor("local-only").should == fixture.config.sessionDatabase;
    catalog.databaseFor(null).should == managed;

    string message = JSONValue(["role": JSONValue("assistant"), "content": JSONValue("local history")]).toString();
    local.query("insert into message_nodes values ('local-only', 3, null, ?, 100)", message);
    catalog.messages("local-only")[0]["content"].str.should == "local history";
    catalog.messages("session-one").array.length.should == 0;
}

@Name("Catalog chooses the native lock directory for a loaded session before its first database save")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    mkdirRecurse(fixture.config.sessionLockDir);
    string path = buildPath(fixture.config.sessionLockDir, "provisional.lock");
    File lock = File(path, "w");
    scope(exit)
        lock.close();

    flock(lock.fileno, LOCK_EX).should == 0;
    Catalog catalog = new Catalog(buildPath(fixture.root, "partition", "sessions.db"),
        fixture.config.sessionDatabase, fixture.config.sessionLockDir);
    catalog.databaseFor("provisional").should == fixture.config.sessionDatabase;
    catalog.lockPath("provisional").should == path;
    fixture.bridge.online("provisional").should == true;
}
