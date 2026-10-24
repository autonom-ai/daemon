module tests.http.bindings;

import tests.common;
import tests.http.common;

import unit_threaded : Name, Serial, should;

import std.array : replicate;
import std.file : exists, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath;

@Name("An admitted start cannot reclaim a profile after an explicit rebind") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue first = hookSession(fixture, "session-a", "held");
    request("/api/profiles/held")["session"]["id"].str.should == "session-a";
    finishHookSession(first);

    write(buildPath(fixture.root, "next-session-id"), "session-b");
    JSONValue second = request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("barrier"),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue("held")
    ]).toString());
    string barrierPath = buildPath(fixture.root, "barrier-session-b");
    string tokenPath = buildPath(fixture.root, "session-b.token");
    waitUntil(delegate bool() {
        return exists(barrierPath) && exists(tokenPath);
    });
    string runToken = readText(tokenPath);
    hookTokens["session-b"] = runToken;

    request("/api/profiles/held/session", 200, `{"id":"session-c"}`);

    // The stale SessionStart hook authenticates but must not publish a binding.
    request("/api/hooks/session-start", 200, JSONValue([
        "hook_event_name": JSONValue("SessionStart"),
        "session_id": JSONValue("session-b")
    ]).toString());

    // Own-session registrations for the stale scoped call are rejected.
    request("/api/profiles/held/session", 409, `{"id":"session-b"}`,
        "application/json", HTTP.Method.post, runToken, "session-b", false);
    string capability = "b".replicate(64);
    request("/api/acp/admit", 200, JSONValue([
        "connection": JSONValue("00000000-0000-0000-0000-0000000000b1"),
        "session": JSONValue("session-b"),
        "token": JSONValue(capability),
        "directory": JSONValue(fixture.root)
    ]).toString());
    request("/api/profiles/held/session", 409, `{"id":"session-b"}`,
        "application/json", HTTP.Method.post, null, "session-b", false, capability);

    write(buildPath(fixture.root, "release-completions"), "");
    string indexPath = buildPath(fixture.config.dataDir, "executions", "index.json");
    string statePath = buildPath(fixture.config.dataDir, "agents", "state.json");
    waitUntil(delegate bool() {
        if (!exists(indexPath) || !exists(statePath))
            return false;

        JSONValue index = parseJSON(readText(indexPath));
        JSONValue state = parseJSON(readText(statePath));
        JSONValue* record = second["id"].str in index["executions"].object;
        JSONValue* binding = "held" in state["bindings"].object;
        return record !is null && (*record)["status"].str == "succeeded" &&
            binding !is null && binding.type == JSONType.string && binding.str == "session-c";
    });
}
