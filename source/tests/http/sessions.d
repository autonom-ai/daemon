module tests.http.sessions;

import tests.common;
import tests.http.common;

import unit_threaded : Name, Serial, should;

static import core.sys.posix.signal;

import core.stdc.errno : errno, ESRCH;
import core.time : seconds;

import std.array : replicate;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : append, exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath;
import std.process;
import std.string : strip;

@Name("Backend completion refreshes worker-owned bindings without unrelated HTTP traffic") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("quiet completion"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("quiet")
    ]).toString());
    string statePath = buildPath(fixture.config.dataDir, "agents", "state.json");
    // Observe disk only: an HTTP poll would itself perform the refresh being tested.
    waitUntil(delegate bool() {
        if (!exists(statePath))
            return false;

        JSONValue state = parseJSON(readText(statePath));
        return "quiet" in state["bindings"].object && state["bindings"]["quiet"].type == JSONType.string;
    });
    (request("/api/profiles/quiet")["session"]["id"].str.length > 0).should == true;
    request("/api/worker/refresh", 405);
    request("/api/worker/refresh", 400, `{"extra":true}`);
    request("/api/worker/refresh", 403, "{}", "application/json", HTTP.Method.post, null, null, false);
}

@Name("Ten simultaneous completions progress without traffic and retain bindings under pressure") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    // Retention pressure tests binding preservation; this does not force overflow or a full batch.
    append(fixture.path, "maxConcurrentCalls: 12\ncallCapacity: 4\n");
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    string[] executions;
    foreach (i; 0..10)
    {
        string sessionId = "burst-" ~ i.to!string;
        write(buildPath(fixture.root, "next-session-id"), sessionId);
        JSONValue reply = request("/api/sessions", 202, JSONValue([
            "prompt": JSONValue("barrier"),
            "directory": JSONValue(fixture.root),
            "profile": JSONValue(sessionId)
        ]).toString());
        executions ~= reply["id"].str;
        // The marker proves the fake consumed next-session-id before it is rewritten.
        waitUntil(delegate bool() {
            return exists(buildPath(fixture.root, "barrier-" ~ sessionId));
        });
    }

    write(buildPath(fixture.root, "release-completions"), "release");

    string indexPath = buildPath(fixture.config.dataDir, "executions", "index.json");
    string statePath = buildPath(fixture.config.dataDir, "agents", "state.json");
    // Observe disk only: any HTTP request would itself run the refresh under test.
    waitUntil(delegate bool() {
        if (!exists(indexPath) || !exists(statePath))
            return false;

        JSONValue index = parseJSON(readText(indexPath));
        JSONValue state = parseJSON(readText(statePath));
        foreach (id; executions)
        {
            JSONValue* record = id in index["executions"].object;
            if (record is null || (*record)["status"].str != "succeeded")
                return false;
        }
        foreach (i; 0..10)
        {
            string name = "burst-" ~ i.to!string;
            JSONValue* bound = name in state["bindings"].object;
            if (bound is null || bound.type != JSONType.string || bound.str != name)
                return false;
        }
        return true;
    });
}

@Name("Profile binding survives provider-catalog omission and call eviction") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    write(buildPath(fixture.root, "omit-catalog"), "");
    append(fixture.path, "callCapacity: 1\n");
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    string firstSession = "unlisted-completed";
    write(buildPath(fixture.root, "next-session-id"), firstSession);
    JSONValue first = request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("complete without catalog"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("unlisted-profile")
    ]).toString());
    string firstExecution = first["id"].str;
    string indexPath = buildPath(fixture.config.dataDir, "executions", "index.json");
    string statePath = buildPath(fixture.config.dataDir, "agents", "state.json");
    waitUntil(delegate bool() {
        if (!exists(indexPath) || !exists(statePath))
            return false;

        JSONValue index = parseJSON(readText(indexPath));
        JSONValue state = parseJSON(readText(statePath));
        JSONValue* record = firstExecution in index["executions"].object;
        JSONValue* binding = "unlisted-profile" in state["bindings"].object;
        return record !is null && (*record)["status"].str == "succeeded" &&
            binding !is null && binding.type == JSONType.string && binding.str == firstSession;
    });

    write(buildPath(fixture.root, "next-session-id"), "evictor-session");
    JSONValue second = request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("evict first execution"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("evictor")
    ]).toString());
    string secondExecution = second["id"].str;
    waitUntil(delegate bool() {
        if (!exists(indexPath) || !exists(statePath))
            return false;

        JSONValue index = parseJSON(readText(indexPath));
        JSONValue state = parseJSON(readText(statePath));
        JSONValue* firstRecord = firstExecution in index["executions"].object;
        JSONValue* secondRecord = secondExecution in index["executions"].object;
        JSONValue* binding = "unlisted-profile" in state["bindings"].object;
        return firstRecord !is null && (*firstRecord)["status"].str == "succeeded" &&
            secondRecord !is null && (*secondRecord)["status"].str == "succeeded" &&
            binding !is null && binding.type == JSONType.string && binding.str == firstSession;
    });

    exists(fixture.config.sessionDatabase).should == false;
    request("/api/profiles/unlisted-profile")["session"]["id"].str.should == firstSession;
}

@Name("Closing the fixture daemon reaps its hanging fake backend") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    string sessionId = "teardown-hang";
    write(buildPath(fixture.root, "next-session-id"), sessionId);
    request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("hang"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("teardown")
    ]).toString());

    string callsPath = buildPath(fixture.root, "acp-calls.jsonl");
    string pidPath = buildPath(fixture.root, "hanging-backend-" ~ sessionId ~ ".pid");
    waitUntil(delegate bool() {
        return exists(callsPath) && readText(callsPath).canFind(`"text": "hang"`) && exists(pidPath);
    });
    int backendPid = to!int(readText(pidPath).strip);

    daemon.close();
    daemon.close();
    waitUntil(delegate bool() {
        return core.sys.posix.signal.kill(backendPid, 0) == -1 && errno == ESRCH;
    }, 10.seconds);
}

@Name("Refresh does not rebind a profile to an earlier daemon-launched session") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue first = hookSession(fixture, "managed-first", "alpha");
    request("/api/profiles/alpha")["session"]["id"].str.should == "managed-first";
    finishHookSession(first);
    JSONValue second = hookSession(fixture, "managed-second", "alpha");
    foreach (i; 0..3)
        request("/api/profiles/alpha")["session"]["id"].str.should == "managed-second";

    finishHookSession(second);
    request("/api/profiles/alpha")["session"]["id"].str.should == "managed-second";
}

@Name("A starting profile is reserved before the first hook identifies its session") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue first = hookSession(fixture, "reserved-first", "reserved", false);
    JSONValue launch = JSONValue([
        "prompt": JSONValue("auth:reserved-second"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("RESERVED")
    ]);
    request("/api/sessions", 409, launch.toString());
    launch["profile"] = JSONValue("HUMAN");
    request("/api/sessions", 400, launch.toString());
    finishHookSession(first);
}

@Name("Daemon admits observed sessions and binds MCP capabilities") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    string connection = "00000000-0000-0000-0000-000000000001";
    string capability = "a".replicate(64);
    request("/api/acp/admit", 200, JSONValue([
        "connection": JSONValue(connection),
        "session": JSONValue("obs-1"),
        "token": JSONValue(capability),
        "directory": JSONValue(fixture.root)
    ]).toString());
    request("/api/acp/admit", 400, `{"connection":"nope","session":"obs-2","token":"`~capability~`"}`);
    request("/api/acp/admit", 400, JSONValue([
        "connection": JSONValue(connection),
        "session": JSONValue("obs-2"),
        "token": JSONValue("not-hex")
    ]).toString());
    request("/api/acp/admit", 409, JSONValue([
        "connection": JSONValue(connection),
        "session": JSONValue("obs-other"),
        "token": JSONValue(capability)
    ]).toString());

    request("/api/mcp/session", 403)["error"].str.should == "MCP capability is not bound to a session";
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.undefined,
        null, null, true, "b".replicate(64));
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.get,
        null, null, false);
    JSONValue identity = request("/api/mcp/session?session=other", 200, null, "application/json",
        HTTP.Method.get, null, null, false, capability);
    identity.object.length.should == 1;
    identity["id"].str.should == "obs-1";
    request("/api/mcp/session", 405, "{}", "application/json", HTTP.Method.post,
        null, null, false, capability)["error"].str.should == "Method not allowed";

    string tokenPath = buildPath(fixture.config.dataDir, "mcp", "obs-1.token");
    readText(tokenPath).should == capability;

    request("/api/profiles", 201, `{"name":"warden"}`);
    request("/api/profiles/warden/session", 200, `{"id":"obs-1"}`);
    request("/api/rooms?session=obs-1", 200, null, "application/json", HTTP.Method.undefined,
        null, null, false, capability);
    request("/api/rooms?session=obs-1", 403, null, "application/json", HTTP.Method.undefined,
        null, null, false);
    request("/api/rooms?session=other", 403, null, "application/json", HTTP.Method.undefined,
        null, null, false, capability);

    mkdirRecurse(buildPath(fixture.root, ".devin"));
    write(buildPath(fixture.root, ".devin", "policy.yml"), "rules:\n  - action: allow\n");
    JSONValue hook = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("obs-1"),
        "tool_name": JSONValue("mcp__autonom-coord__read_events"),
        "tool_input": JSONValue.emptyObject
    ]);
    JSONValue admitted = request("/api/hooks/pre-tool-use", 200, hook.toString(),
        "application/json", HTTP.Method.undefined, null, null, true, capability);
    admitted["hookSpecificOutput"]["updatedInput"]["session_id"].str.should == "obs-1";
    request("/api/hooks/pre-tool-use", 200, hook.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, hook.toString(), "application/json",
        HTTP.Method.undefined, null, null, true, "b".replicate(64))["decision"].str.should == "block";

    request("/api/acp/observe", 200, JSONValue([
        "connection": JSONValue(connection),
        "sessions": JSONValue.emptyArray,
        "closed": JSONValue(true)
    ]).toString());
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.undefined,
        null, null, true, capability);
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.get,
        null, null, false, capability);
    exists(tokenPath).should == false;
}
