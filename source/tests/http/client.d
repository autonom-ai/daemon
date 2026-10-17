module tests.http.client;

import tests.http.common;
import tests.common;
import tests.interop.devin.common : database;

import arsd.sqlite;
import unit_threaded : Name, Serial, should;

import core.sys.linux.sys.file : flock, LOCK_EX;
import core.thread : Thread;
import core.time : Duration, msecs, seconds;
import std.algorithm : canFind;
import std.array : join, replace, replicate;
import std.conv : octal, to;
import std.file : exists, getcwd, mkdirRecurse, readText, setAttributes, write;
import std.json : JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;
import std.path : buildPath;
import std.process;
import std.stdio : File, stdin;

@Name("Human chat uses its own cursors and can DM, ping, and participate in rooms") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    hookSession(fixture, "managed-one");
    request("/api/profiles", 201, `{"name":"alpha"}`);
    request("/api/profiles/alpha/session", 200, `{"id":"managed-one"}`);
    request("/api/rooms", 201, `{"name":"team"}`);
    request("/api/rooms/team/messages", 201, `{"text":"human check-in","ping":["alpha"]}`)["from"].str
        .should == "human";
    request("/api/rooms/team/messages")["messages"].array.length.should == 1;
    request("/api/rooms/team/messages?session=managed-one")["messages"].array.length.should == 1;
    request("/api/messages", 201, `{"to":"alpha","text":"direct from human"}`);
    request("/api/messages?session=managed-one", 201, `{"to":"human","text":"direct from alpha","ping":["human"]}`);
    JSONValue direct = request("/api/messages?source=dms");
    direct["messages"].array.length.should == 1;
    direct["messages"][0]["from"].str.should == "alpha";
    request("/api/messages?source=pings")["messages"].array.length.should == 1;
    request("/api/events")["events"].array.length.should == 0;
    request("/api/events?profile=alpha")["events"].array.length.should == 1;
    request("/api/messages?session=managed-one&source=dms")["messages"].array.length.should == 1;
}

@Name("Client state shares current session metadata across profiles and directory-filtered listings") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Sqlite connection = database(fixture);
    scope(exit)
        destroy(connection);

    fixture.store.register("alpha", "session-one");
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue profile = request("/api/profiles/alpha");
    profile["session"]["title"].str.should == "First title";
    connection.query("update sessions set title = 'Updated title', working_directory = '/elsewhere'");
    JSONValue sessions = request("/api/sessions?directory="~fixture.root);
    sessions.array.length.should == 0;
    request("/api/profiles/alpha")["session"]["title"].str.should == "Updated title";
    JSONValue elsewhere = request("/api/sessions?directory=/elsewhere");
    elsewhere.array.length.should == 1;
    request("/api/profiles/alpha")["session"]["title"].should == elsewhere[0]["title"];
    connection.query("delete from sessions");
    request("/api/sessions").array.length.should == 0;
    request("/api/profiles/alpha")["session"]["title"].str.should == "";
}
