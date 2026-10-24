module tests.interop.devin.completion;

import daemon.interop.call : Call, CallStatus;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.session : Session;
import tests.common;

import unit_threaded : Name, should;

import core.stdc.errno : errno, ESRCH;
import core.sync.mutex : Mutex;
import core.sys.posix.signal : kill;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.string : strip;

@Name("Bridge drains overflowed completions in finite eight-call passes")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Mutex wakeMutex = new Mutex();
    size_t wakeCount;
    Bridge bridge = new Bridge(fixture.config, null, {
        synchronized (wakeMutex)
            ++wakeCount;
    });
    bridge.callCapacity = 4;
    scope(exit)
        bridge.close();

    Call[] calls;
    string[] sessionIds;
    foreach (i; 0..66)
    {
        string sessionId = "overflow-" ~ i.to!string;
        write(buildPath(fixture.root, "next-session-id"), sessionId);
        Call execution = bridge.print("overflow " ~ i.to!string, fixture.root);
        execution.wait();
        calls ~= execution;
        sessionIds ~= sessionId;
    }
    synchronized (wakeMutex)
        wakeCount.should == 66;

    bridge.collect();
    size_t collected;
    foreach (execution; calls)
        collected += execution.isCollected;
    collected.should == 8;

    size_t passes = 1;
    foreach (i; 0..8)
    {
        if (collected == calls.length)
            break;

        bridge.collect();
        size_t nextCollected;
        foreach (execution; calls)
            nextCollected += execution.isCollected;
        (nextCollected >= collected).should == true;
        (nextCollected - collected <= 8).should == true;
        collected = nextCollected;
        ++passes;
    }
    (passes <= 9).should == true;
    collected.should == 66;
    (bridge.listCalls().length <= 4).should == true;

    JSONValue index = parseJSON(readText(buildPath(bridge.executionDir, "index.json")));
    foreach (execution; calls)
    {
        JSONValue* record = execution.id in index["executions"].object;
        (record !is null).should == true;
        (*record)["status"].type.should == JSONType.string;
        (*record)["status"].str.should == "succeeded";
    }

    Session[] retained = bridge.retainedSessions();
    retained.length.should == 66;
    foreach (sessionId; sessionIds)
    {
        bool found;
        foreach (session; retained)
            found = found || session.id == sessionId;
        found.should == true;
    }
}

@Name("Bridge close records final outcomes and rejects late completions and work")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Mutex wakeMutex = new Mutex();
    size_t wakes;
    Bridge bridge = new Bridge(fixture.config, null, {
        synchronized (wakeMutex)
            ++wakes;
    });
    scope(exit)
        bridge.close();

    write(buildPath(fixture.root, "next-session-id"), "closing-done");
    Call completed = bridge.print("done", fixture.root);
    completed.wait();
    completed.status.should == CallStatus.Succeeded;

    write(buildPath(fixture.root, "next-session-id"), "closing-hang");
    Call hanging = bridge.print("hang", fixture.root);
    string marker = buildPath(fixture.root, "hanging-backend-closing-hang.pid");
    waitUntil(delegate bool() { return exists(marker); });
    int backend = readText(marker).strip.to!int;

    bridge.close();
    bridge.close();

    completed.status.should == CallStatus.Succeeded;
    hanging.status.should == CallStatus.Stopped;

    JSONValue index = parseJSON(readText(buildPath(bridge.executionDir, "index.json")));
    JSONValue* doneRecord = completed.id in index["executions"].object;
    (doneRecord !is null).should == true;
    (*doneRecord)["status"].str.should == "succeeded";
    JSONValue* hungRecord = hanging.id in index["executions"].object;
    (hungRecord !is null).should == true;
    (*hungRecord)["status"].str.should == "stopped";

    waitUntil(delegate bool() { return kill(backend, 0) == -1 && errno == ESRCH; });

    // The hanging call's monitor posted after the handoff closed, so it never woke.
    synchronized (wakeMutex)
        wakes.should == 1;

    bool rejected;
    try
        bridge.print("after-close", fixture.root);
    catch (Exception)
        rejected = true;
    rejected.should == true;
    bridge.listCalls().length.should == 2;
    readText(buildPath(fixture.root, "acp-calls.jsonl")).canFind("after-close").should == false;
}
