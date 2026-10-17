module tests.http.client;

import tests.http.common;
import tests.common;
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
    request("/api/client/messages?source=room&target=team").array.length.should == 1;
    request("/api/rooms/team/messages?session=managed-one")["messages"].array.length.should == 1;
    request("/api/messages", 201, `{"to":"alpha","text":"direct from human"}`);
    request("/api/messages?session=managed-one", 201, `{"to":"human","text":"direct from alpha","ping":["human"]}`);
    JSONValue direct = request("/api/client/messages?source=dm&target=alpha");
    direct.array.length.should == 2;
    direct[0]["from"].str.should == "human";
    direct[1]["from"].str.should == "alpha";
    request("/api/client/messages?source=pings").array.length.should == 1;
    request("/api/client/state")["humanEvents"].integer.should == 0;
    request("/api/client/events?profile=alpha").array.length.should == 1;
    request("/api/messages?session=managed-one&source=dms")["messages"].array.length.should == 1;
}

