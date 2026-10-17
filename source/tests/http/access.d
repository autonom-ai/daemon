module tests.http.access;

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

@Name("Unmanaged sessions cannot acquire Autonom identity through hooks") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue payload = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("desktop-session"),
        "tool_name": JSONValue("mcp__autonom-coord__set_profile"),
        "tool_input": JSONValue(["name": JSONValue("intruder")])
    ]);
    JSONValue response = request("/api/hooks/pre-tool-use", 200, payload.toString());
    response["decision"].str.should == "block";
    ("hookSpecificOutput" in response.object).should == null;
    request("/api/profiles").array.length.should == 0;
}

@Name("Managed capabilities are bound to one live run and cannot be forged or reused") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue first = hookSession(fixture, "managed-one");
    hookSession(fixture, "managed-two");
    string token = hookTokens["managed-one"];
    request(
        "/api/profiles",
        403,
        null,
        "application/json",
        HTTP.Method.get,
        null,
        "managed-one",
        false
    );
    request(
        "/api/profiles",
        200,
        null,
        "application/json",
        HTTP.Method.get,
        token,
        "managed-one",
        false
    );
    request(
        "/api/profiles",
        403,
        null,
        "application/json",
        HTTP.Method.get,
        token,
        "managed-two",
        false
    );
    request("/api/profiles", 201, `{"name":"alpha"}`);
    request(
        "/api/profiles/alpha/session",
        409,
        `{"id":"managed-two"}`,
        "application/json",
        HTTP.Method.post,
        token,
        "managed-one",
        false
    );
    request(
        "/api/profiles/alpha/session",
        200,
        `{"id":"managed-one"}`,
        "application/json",
        HTTP.Method.post,
        token,
        "managed-one",
        false
    );
    request("/api/profiles/alpha")["session"]["id"].str.should == "managed-one";
    finishHookSession(first);
    request(
        "/api/profiles",
        403,
        null,
        "application/json",
        HTTP.Method.get,
        token,
        "managed-one",
        false
    );
    request("/api/sessions/desktop-session/resume", 409,
        JSONValue(["prompt": JSONValue("hello"), "directory": JSONValue(fixture.root)]).toString());
}

