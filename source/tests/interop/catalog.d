module tests.interop.catalog;

import daemon.interop;
import tests.common;
import tests.interop.devin.common : database;

import arsd.sqlite;
import unit_threaded;

import std.json : JSONException;
import std.uuid : randomUUID;

@Name("Bridge lists database sessions without invoking the CLI or granting control")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);

    Session[] sessions = fixture.bridge.list(fixture.root);
    sessions.length.should == 1;
    sessions[0].id.should == "session-one";
    (sessions[0] is fixture.bridge.findSession("session-one")).should == true;
    sessions[0].title.should == "First title";
    fixture.bridge.access.managed("session-one").should == false;
    fixture.bridge.list("/elsewhere").length.should == 0;
}

@Name("Bridge omits deleted and unknown sessions even when a handle was cached")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);

    fixture.bridge.findSession("session-one").shouldNotBeNull;
    connection.query("delete from sessions where id = 'session-one'");
    fixture.bridge.findSession("session-one").shouldBeNull;
    fixture.bridge.findSession("missing").shouldBeNull;
    fixture.bridge.list().length.should == 0;
}

@Name("Bridge filters provisional observed sessions by their connection workspace and origin")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.bridge.observeConnection(randomUUID().toString(), ["provisional"],
        ["provisional": fixture.root], ["provisional": false], false);
    Session[] listed = fixture.bridge.list(fixture.root, "autonom");
    listed.length.should == 1;
    listed[0].id.should == "provisional";
    listed[0].workspace.should == fixture.root;
    fixture.bridge.list("/elsewhere", "autonom").length.should == 0;
}

@Name("Bridge leaves an unmarked session's ACP origin unknown")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);

    fixture.bridge.list()[0].metadata.acp.length.should == 0;
    fixture.bridge.list(null, "autonom").length.should == 0;
    fixture.bridge.access.remember("session-one", false);
    fixture.bridge.list(null, "autonom").length.should == 0;
}

@Name("Bridge filters persisted connector metadata after restart independently of admission")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);
    connection.query("update sessions set metadata = ? where id = 'session-one'",
        `{"client_meta":{"autonom/connector":"autonom"}}`);

    Bridge restarted = new Bridge(fixture.config);
    scope(exit) restarted.close();
    restarted.list(null, "autonom")[0].id.should == "session-one";
    restarted.list(null, "other").length.should == 0;
    restarted.access.managed("session-one").should == false;
}

@Name("Bridge reports malformed metadata during catalog listing")
@ShouldFailWith!JSONException
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);
    connection.query("update sessions set metadata = '{' where id = 'session-one'");

    fixture.bridge.list();
}

@Name("Bridge reports malformed metadata during session lookup")
@ShouldFailWith!JSONException
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    Sqlite connection = database(fixture);
    scope(exit) destroy(connection);
    connection.query("update sessions set metadata = '{' where id = 'session-one'");

    fixture.bridge.findSession("session-one");
}
