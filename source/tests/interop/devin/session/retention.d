module tests.interop.devin.session.retention;

import daemon.agent;
import daemon.config : Config;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.calls;
import daemon.interop.devin.history;
import daemon.interop.devin.session.api : removeSessions;
import daemon.interop.devin.session.catalog;
import daemon.interop.devin.session.control;
import daemon.interop.session;
import daemon.interop;
import tests.common;
import tests.http.common;

import serverino : endpoint, route;
import unit_threaded;

import core.sys.linux.sys.file : flock, LOCK_EX;
import core.time : MonoTime, minutes, seconds;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : to;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process : environment;
import std.stdio : File;
import std.traits : hasUDA;

@Name("Call registry evicts oldest settled tickets strictly in LRU order when capacity exceeds 128")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call[] calls;
    foreach (i; 0..135)
    {
        Call call = fixture.bridge.print("call "~i.to!string, fixture.root);
        call.wait();
        call.settled = MonoTime.currTime - (200 - i).seconds;
        calls ~= call;
    }

    fixture.bridge.listCalls().length.should == 135;

    fixture.bridge.collect();

    fixture.bridge.listCalls().length.should == 128;

    foreach (i; 0..7)
        fixture.bridge.execution(calls[i].id).shouldBeNull;

    foreach (i; 7..135)
        fixture.bridge.execution(calls[i].id).shouldNotBeNull;
}

@Name("Bridge collect never evicts running calls even if capacity is exceeded")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call runningCall = fixture.bridge.start("hang", fixture.root, "SWE-2");

    Call[] settled;
    foreach (i; 0..130)
    {
        Call c = fixture.bridge.print("settled "~i.to!string, fixture.root);
        c.wait();
        c.settled = MonoTime.currTime - (150 - i).seconds;
        settled ~= c;
    }

    fixture.bridge.collect();

    fixture.bridge.execution(runningCall.id).shouldNotBeNull;
    fixture.bridge.execution(runningCall.id).running.should == true;
}

@Name("Settled calls expire after callSettleTimeout regardless of capacity")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call call = fixture.bridge.print("quick call", fixture.root);
    call.wait();

    fixture.bridge.listCalls().length.should == 1;

    call.settled = MonoTime.currTime - 301.seconds;

    fixture.bridge.collect();

    fixture.bridge.execution(call.id).shouldBeNull;
}
