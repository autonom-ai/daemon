module tests.http.sessions;

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

    request("/api/mcp/session", 403);
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.undefined,
        null, null, true, "b".replicate(64));
    request("/api/mcp/session", 200, null, "application/json", HTTP.Method.undefined,
        null, null, true, capability)["id"].str.should == "obs-1";

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
    exists(tokenPath).should == false;
}
