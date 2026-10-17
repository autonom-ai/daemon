module tests.interop.session;

import daemon.agent;
import daemon.config : Config;
import daemon.interop;
import daemon.interop.api : removeSessions;
import daemon.interop.session;
import tests.common;
import tests.http.common;
import serverino : endpoint, route;
import unit_threaded;

import core.sys.linux.sys.file : flock, LOCK_EX;
import core.time : Duration, MonoTime, minutes, msecs, seconds;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : octal, to;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.stdio : File;
import std.string : splitLines;
import std.traits : hasUDA;
import std.uuid : randomUUID;

private:

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
    waitUntil(delegate bool()
    {
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
    waitUntil(delegate bool()
    {
        return session.status == SessionStatus.Online;
    });
    waitUntil(delegate bool()
    {
        return session.execution.acceptingSteer;
    });
    session.steer(prompt);
    waitUntil(delegate bool()
    {
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

@Name("Session strips host agent variables from the CLI environment") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    write(buildPath(fixture.root, "want-environ"), "");

    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    string previousApiKey = environment.get("OPENROUTER_API_KEY");
    environment["ACP_BACKEND"] = "windsurf";
    environment["OPENROUTER_API_KEY"] = "test-router-key";
    environment["WINDSURF_IDE_TYPE"] = "windsurf";
    scope(exit)
    {
        environment.remove("ACP_BACKEND");
        if (previousApiKey is null)
            environment.remove("OPENROUTER_API_KEY");
        else
            environment["OPENROUTER_API_KEY"] = previousApiKey;
        environment.remove("WINDSURF_IDE_TYPE");
    }

    session.resume("hang", fixture.root);
    waitUntil(delegate bool()
    {
        return exists(buildPath(fixture.root, "environ.txt"));
    });
    string spawned = readText(buildPath(fixture.root, "environ.txt"));
    spawned.canFind("ACP_BACKEND=").should == false;
    spawned.canFind("OPENROUTER_API_KEY=").should == false;
    spawned.canFind("WINDSURF_IDE_TYPE=").should == false;
    spawned.canFind("PATH=").should == true;
}

@Name("Session exposes a failed agent turn independently of online status")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    session.resume("fail", fixture.root);
    waitUntil(delegate bool()
    {
        return session.status == SessionStatus.Failed;
    });
    session.exitStatus.get.should == 0;
}


@Name("Bridge restart preserves backend sessions and logs without restoring call tickets")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
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
    scope(exit) restarted.close();
    restarted.execution(call.id).shouldBeNull;
    restarted.findSession(id).shouldNotBeNull;
    readText(restarted.logPath(id)).should == log;
    readText(record).should == original;
}

@Name("Call registry evicts oldest settled tickets strictly in LRU order when capacity exceeds 128")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call[] calls;
    foreach (i; 0 .. 135)
    {
        Call call = fixture.bridge.print("call " ~ i.to!string, fixture.root);
        call.wait();
        call.settled = MonoTime.currTime - (200 - i).seconds;
        calls ~= call;
    }

    fixture.bridge.executionCount.should == 135;

    fixture.bridge.collect();

    fixture.bridge.executionCount.should == 128;

    foreach (i; 0 .. 7)
    {
        fixture.bridge.execution(calls[i].id).shouldBeNull;
    }

    foreach (i; 7 .. 135)
    {
        fixture.bridge.execution(calls[i].id).shouldNotBeNull;
    }
}

@Name("Bridge collect never evicts running calls even if capacity is exceeded")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call runningCall = fixture.bridge.newCall(CallKind.Start, fixture.root, "SWE-2");
    fixture.bridge.registerExecution(runningCall);

    Call[] settled;
    foreach (i; 0 .. 130)
    {
        Call c = fixture.bridge.print("settled " ~ i.to!string, fixture.root);
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

    fixture.bridge.executionCount.should == 1;

    call.settled = MonoTime.currTime - 301.seconds;

    fixture.bridge.collect();

    fixture.bridge.execution(call.id).shouldBeNull;
}

@Name("Transcript lookup resolves historical execution ID and falls back to disk logs after memory eviction")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call call = fixture.bridge.print("durable transcript turn text", fixture.root);
    call.wait();
    string executionId = call.id;
    string sessionId = call.sessionId;

    call.settled = MonoTime.currTime - 301.seconds;
    fixture.bridge.collect();

    fixture.bridge.execution(executionId).shouldBeNull;

    string mappedSession = fixture.bridge.sessionForExecution(executionId);
    mappedSession.should == sessionId;

    JSONValue record = fixture.bridge.executionRecord(executionId);
    (record.type != JSONType.null_).should == true;
    record["id"].str.should == executionId;
    record["status"].str.should == "succeeded";

    string outPath = buildPath(fixture.bridge.executionDir, executionId ~ ".out");
    exists(outPath).should == true;
    readText(outPath).canFind("durable transcript turn text").should == true;
}

@Name("Retention configuration parses knobs with backward-compatible defaults and custom values")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.maxStreamBytes.should == 4 * 1024 * 1024;
    fixture.config.maxStreamEntries.should == 1000;
    fixture.config.callCapacity.should == 128;
    fixture.config.callSettleTimeout.should == 300.seconds;
    fixture.config.maxConcurrentCalls.should == 8;
    fixture.config.pruneExecutionArtifacts.should == false;
    fixture.config.allowDestructivePruning.should == false;

    string customConfig = buildPath(fixture.root, "custom_retention.yml");
    write(customConfig, "devinCommand: devin\n" ~
        "maxStreamBytes: 16MiB\n" ~
        "maxStreamEntries: 2000\n" ~
        "callCapacity: 64\n" ~
        "callSettleTimeout: 10m\n" ~
        "maxConcurrentCalls: 4\n" ~
        "pruneExecutionArtifacts: true\n" ~
        "allowDestructivePruning: true\n" ~
        ROUTER);

    Config custom = new Config(customConfig);
    custom.maxStreamBytes.should == 16 * 1024 * 1024;
    custom.maxStreamEntries.should == 2000;
    custom.callCapacity.should == 64;
    custom.callSettleTimeout.should == 10.minutes;
    custom.maxConcurrentCalls.should == 4;
    custom.pruneExecutionArtifacts.should == true;
    custom.allowDestructivePruning.should == true;
}

@Name("Transcript endpoint resolves managed session even after call ticket is evicted") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue res = hookSession(fixture, "managed-hist-session");

    string callId = res["id"].str;
    callId.length.should == 36;

    JSONValue transcript = request("/api/executions/" ~ callId ~ "/transcript");
    (transcript["session"].type != JSONType.null_).should == true;
    transcript["session"]["id"].str.should == "managed-hist-session";
    (transcript["messages"].type == JSONType.array).should == true;
}

