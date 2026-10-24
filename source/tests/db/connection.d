module tests.db.connection;

import daemon.db : Connection;
import daemon.db.profiles : Profiles;
import tests.common : Fixture;

import arsd.sqlite : Sqlite, queryOneColumn, SQLITE_OPEN_READONLY;
import unit_threaded : Name, should, shouldThrow;

import core.thread : Thread;
import std.conv : octal;
import std.file : readText, remove, setAttributes, symlink, write;
import std.path : buildPath;

@Name("Domain database enforces worker ownership and explicit connection lifetime")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    Profiles profiles = new Profiles(connection);
    bool refused;
    Thread producer = new Thread({
        try
            profiles.create("offthread");
        catch (Exception)
            refused = true;
    });
    producer.start();
    producer.join();
    refused.should == true;
    profiles.list().length.should == 0;
    connection.transaction({
        profiles.create("nested");
    }).shouldThrow!Exception();
    profiles.list().length.should == 0;
    profiles.create("worker");
    connection.close();
    connection.close();
    profiles.list().shouldThrow!Exception();
}

@Name("Domain database rejects foreign schemas and future versions without changing them")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    string path = buildPath(fixture.config.dataDir, "autonom.db");
    Sqlite foreign = new Sqlite(path);
    foreign.query("create table vendor_state(value text)");
    foreign.query("insert into vendor_state values (?)", "preserved");
    destroy(foreign);
    setAttributes(path, octal!"600");
    new Connection(fixture.config.dataDir).shouldThrow!Exception();
    Sqlite inspected = new Sqlite(path, SQLITE_OPEN_READONLY);
    inspected.queryOneColumn!string("select value from vendor_state").should == "preserved";
    inspected.queryOneColumn!int("pragma user_version").should == 0;
    destroy(inspected);
    remove(path);

    Connection connection = new Connection(fixture.config.dataDir);
    connection.close();
    foreign = new Sqlite(path);
    foreign.query("pragma user_version = 99");
    destroy(foreign);
    new Connection(fixture.config.dataDir).shouldThrow!Exception();
    inspected = new Sqlite(path, SQLITE_OPEN_READONLY);
    inspected.queryOneColumn!int("pragma user_version").should == 99;
    destroy(inspected);
}

@Name("Domain database refuses symlinks and insecure files without touching their targets")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    string target = buildPath(fixture.root, "target");
    string path = buildPath(fixture.config.dataDir, "autonom.db");
    write(target, "preserve this file");
    symlink(target, path);
    new Connection(fixture.config.dataDir).shouldThrow!Exception();
    readText(target).should == "preserve this file";
    remove(path);
    write(path, "");
    setAttributes(path, octal!"644");
    new Connection(fixture.config.dataDir).shouldThrow!Exception();
    readText(path).should == "";
}
