module tests.session;

import daemon.agent;
import daemon.interop;
import daemon.interop.session;
import tests.common;
import serverino : endpoint, route;
import unit_threaded : Name, Serial, should, shouldThrow;

import core.sys.linux.sys.file : flock, LOCK_EX;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : octal, to;
import std.file;
import std.json : JSONValue, parseJSON;
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
    Execution execution = fixture.bridge.start("create work", fixture.root, "SWE-2");
    execution.wait();
    execution.status.should == ExecutionStatus.Succeeded;
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
    Execution execution = fixture.bridge.start("create work", fixture.root);
    execution.wait();
    execution.status.should == ExecutionStatus.Failed;
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

@Name("Bridge marks an execution interrupted when its recorded process was lost")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    session.resume("hang", fixture.root);
    waitUntil(delegate bool()
    {
        return session.isRunning();
    });

    string id = session.execution.id;
    fixture.bridge.close();
    string recordPath = buildPath(fixture.config.dataDir, "executions", id~".json");
    JSONValue data = parseJSON(readText(recordPath));
    data["status"] = JSONValue("running");
    data["exitStatus"] = JSONValue(null);
    write(recordPath, data.toString());

    Devin restarted = new Devin(fixture.config);
    scope(exit)
        restarted.close();

    Session recovered = restarted.session("session-1");
    recovered.execution.status.should == ExecutionStatus.Interrupted;
    recovered.status.should == SessionStatus.Failed;
    recovered.exitStatus.isNull.should == true;
}

@Name("Execution records retain their readable versions and interrupted state")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    mkdirRecurse(fixture.bridge.executionDir);
    string[] ids;
    foreach (recordVersion; [1, 2, 3])
    {
        string id = randomUUID().toString();
        ids ~= id;
        write(buildPath(fixture.bridge.executionDir, id~".json"),
            `{"version":`~recordVersion.to!string~`,"id":"`~id~`","kind":"print",`~
            `"workspace":"`~fixture.root~`","model":"","createdAt":"2026-10-15T00:00:00Z",`~
            `"status":"running","sessionId":"session-`~recordVersion.to!string~`","exitStatus":null,"error":null`~
            (recordVersion == 1 ? "" : `,"finishedAt":null`)~
            (recordVersion == 3 ? `,"reply":null,"profile":"","mode":"","trusted":false}` : `}`));
    }

    Devin restarted = new Devin(fixture.config);
    scope(exit)
        restarted.close();

    foreach (index, id; ids)
    {
        Execution execution = restarted.execution(id);
        execution.status.should == ExecutionStatus.Interrupted;
        execution.sessionId.should == "session-"~(index + 1).to!string;
    }
}
