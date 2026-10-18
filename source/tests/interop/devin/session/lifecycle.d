module tests.interop.devin.session.lifecycle;

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

@Name("Session cleanup declares its module-level HTTP endpoint")
unittest
{
    hasUDA!(removeSessions, endpoint).should == true;
    hasUDA!(removeSessions, route).should == true;
}

@Name("Session rejects invalid IDs before launching")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (id; [
        "",
        "../escape",
        "white space",
        "-session",
        "a".replicate(129)
    ])
        fixture.bridge.session(id).shouldThrow!Exception();
}

@Name("Foreign session locks mean loaded elsewhere, not actively running")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Session session = fixture.store.register("marlow", "session-1").session;
    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, session.id~".lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }

    session.status.should == SessionStatus.Offline;
    flock(lock.fileno, LOCK_EX).should == 0;
    session.status.should == SessionStatus.Loaded;
    session.stop().shouldThrow!Exception();
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflictException();
    lock.close();
    waitUntil(delegate bool() {
        return session.status == SessionStatus.Offline;
    });
}

@Name("Session start creates a session through the bridge")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    write(buildPath(fixture.root, "next-session-id"), "fresh-session");
    Call execution = fixture.bridge.start("create work", fixture.root, "SWE-2");
    execution.wait();
    execution.status.should == CallStatus.Succeeded;
    execution.sessionId.should == "fresh-session";
    Session session = fixture.bridge.session(execution.sessionId);
    fixture.bridge.collect();
    session.status.should == SessionStatus.Offline;
    readText(buildPath(fixture.bridge.logDir, "fresh-session.log")).canFind("create work").should == true;
    readText(buildPath(fixture.root, "invocations.txt")).canFind("--print").should == false;
    readText(buildPath(fixture.root, "invocations.txt")).canFind("--export").should == false;
}

@Name("Session start fails when the agent rejects session creation")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    write(buildPath(fixture.root, "fail-new"), "");
    Call execution = fixture.bridge.start("create work", fixture.root);
    execution.wait();
    execution.status.should == CallStatus.Failed;
    execution.sessionId.length.should == 0;
}

@Name("Session resumes through ACP with a supplied model and literal prompt")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    string prompt = "--model dangerous; $(touch forbidden)";
    session.resume("hang", fixture.root, "SWE-2");
    waitUntil(delegate bool() {
        return session.status == SessionStatus.Online;
    });
    waitUntil(delegate bool() {
        return session.execution.acceptingSteer;
    });
    session.steer(prompt);
    waitUntil(delegate bool() {
        if (!exists(buildPath(fixture.root, "acp-calls.jsonl")))
            return false;

        return readText(buildPath(fixture.root, "acp-calls.jsonl")).canFind(prompt);
    });
    session.stop();
    string calls = readText(buildPath(fixture.root, "acp-calls.jsonl"));
    calls.canFind(`"session/load"`).should == true;
    calls.canFind(`"sessionId": "session-1"`).should == true;
    calls.canFind(`"configId": "model"`).should == true;
    calls.canFind(`"value": "SWE-2"`).should == true;
    calls.canFind(prompt).should == true;
    readText(buildPath(fixture.root, "invocations.txt")).canFind("--print").should == false;
    exists(buildPath(fixture.root, "forbidden")).should == false;
}

@Name("Session rejects duplicate resumes and active profile replacement")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.store.register("marlow", "session-1").session;
    scope(exit)
        session.stop();

    session.resume("hang", fixture.root);
    session.resume("work", fixture.root).shouldThrow!Exception();
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflictException();
}

@Name("Session stop reaps owned processes and permits resume")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    session.resume("hang", fixture.root);
    session.stop();
    session.status.should == SessionStatus.Offline;
    session.resume("hang", fixture.root);
    session.isRunning().should == true;
}

@Name("Session exposes a failed agent turn independently of online status")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    session.resume("fail", fixture.root);
    waitUntil(delegate bool() {
        return session.status == SessionStatus.Failed;
    });
    session.exitStatus.get.should == 0;
}

@Name("Bridge restart preserves backend sessions and logs without restoring call tickets")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    Call call = fixture.bridge.start("preserved reply", fixture.root);
    call.wait();
    fixture.bridge.collect();
    string id = call.sessionId;
    string log = readText(fixture.bridge.logPath(id));
    string record = buildPath(fixture.bridge.executionDir, "old-record.json");
    string original = `{"version":2,"status":"running","sessionId":"legacy"}`;
    write(record, original);
    fixture.bridge.close();
    Bridge restarted = new Bridge(fixture.config);
    scope(exit)
        restarted.close();
    restarted.execution(call.id).shouldBeNull;
    restarted.findSession(id).shouldNotBeNull;
    readText(restarted.logPath(id)).should == log;
    readText(record).should == original;
}
