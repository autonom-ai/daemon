module tests.http.server;

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

@Name("Daemon hosts shared state and stops through its HTTP API") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    request("/api/health")["pid"].integer.should == daemon.process.processID;
    request("/api/health", 405, "{}")["error"].str.should == "Method not allowed";

    JSONValue hooks = parseJSON(readText("templates/hooks.v1.json"));
    hooks.object.length.should == 8;
    foreach (event, path; [
        "PreToolUse": "pre-tool-use",
        "PostToolUse": "post-tool-use",
        "PermissionRequest": "permission-request",
        "UserPromptSubmit": "user-prompt-submit",
        "Stop": "stop",
        "PostCompaction": "post-compaction",
        "SessionStart": "session-start",
        "SessionEnd": "session-end"
    ])
    {
        string endpoint = "/api/hooks/"~path;
        JSONValue payload = JSONValue([
            "hook_event_name": JSONValue(event),
            "session_id": JSONValue("hook-session"),
            "prompt_id": JSONValue("hook-prompt"),
            "tool_name": JSONValue("mcp__example__tool"),
            "tool_input": JSONValue(["command": JSONValue("git status")]),
            "tool_response": JSONValue([
                "success": JSONValue(true),
                "output": JSONValue("finished"),
                "error": JSONValue(null)
            ]),
            "prompt": JSONValue("continue"),
            "stop_hook_active": JSONValue(false),
            "summary": JSONValue(null),
            "source": JSONValue("startup"),
            "reason": JSONValue("completed"),
            "future_field": JSONValue([JSONValue(42)])
        ]);
        request(endpoint, 200, payload.toString()).should == parseJSON("{}");
        request(endpoint, 200, JSONValue(["hook_event_name": JSONValue(event)]).toString())
            .should == parseJSON("{}");
        request(endpoint, 405)["error"].str.should == "Method not allowed";
        request(endpoint, 400, "{");
        request(endpoint, 400, "[]");
        request(endpoint, 400, "{}");
        request(endpoint, 400, `{"hook_event_name":42}`);
        request(endpoint, 400, `{"hook_event_name":"Unknown"}`);
        request(endpoint, 400, JSONValue([
            "hook_event_name": JSONValue(event == "PreToolUse" ? "Stop" : "PreToolUse")
        ]).toString());
        request(
            endpoint,
            400,
            payload.toString(),
            "text/plain"
        );
        request(
            endpoint,
            200,
            payload.toString(),
            "application/json; charset=utf-8"
        ).should == parseJSON("{}");
        payload["large"] = JSONValue("x".replicate(64 * 1024));
        request(endpoint, 200, payload.toString());
        payload["large"] = JSONValue("x".replicate(17 * 1024 * 1024));
        request(endpoint, 400, payload.toString());
        payload.object.remove("large");

        hooks[event].array.length.should == 1;
        hooks[event][0]["matcher"].str.should == "";
        hooks[event][0]["hooks"].array.length.should == 1;
        JSONValue hook = hooks[event][0]["hooks"][0];
        hook["type"].str.should == "command";
        hook["timeout"].integer.should == 20;
        hook["command"].str.canFind("hook.py").should == true;
        hooks[event][0]["hooks"][0]["command"] = JSONValue(
            hook["command"].str.replace("{{AUTONOM_ROOT}}", getcwd())
        );
        string command = hooks[event][0]["hooks"][0]["command"].str;
        parseJSON(invokeHook(command, payload)).should == parseJSON("{}");
        parseJSON(invokeHook(command, parseJSON("{}"))).should == parseJSON("{}");
    }

    JSONValue policyRequest = JSONValue([
        "directory": JSONValue(fixture.root),
        "tool": JSONValue("exec"),
        "input": JSONValue(["command": JSONValue("git status")])
    ]);
    request("/api/policy/check", 405)["error"].str.should == "Method not allowed";
    request("/api/policy/check", 400, "{");
    request("/api/policy/check", 400, "{}");
    request(
        "/api/policy/check",
        400,
        policyRequest.toString(),
        "text/plain"
    );
    request("/api/policy/check", 400, `{"directory":"/tmp","tool":"exec","input":[]}`);
    request("/api/policy/check", 400, `{"directory":"/tmp","tool":"exec","unknown":true}`);
    request("/api/policy/check", 503, policyRequest.toString())["denied"].boolean.should == true;
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    string policyPath = buildPath(fixture.root, ".devin", "policy.yml");
    write(policyPath, "rules:\n  - action: allow\n");
    request("/api/policy/check", 200, policyRequest.toString())["denied"].boolean.should == false;
    request("/api/policy/check", 200, policyRequest.toString())["reason"].should == JSONValue(null);
    write(policyPath, "rules:\n  - action: deny\n    reason: Blocked\n");
    request("/api/policy/check", 200, policyRequest.toString())["denied"].boolean.should == true;
    request("/api/policy/check", 200, policyRequest.toString())["reason"].str.should == "Blocked";
    write(policyPath, "rules: []\n");
    request("/api/policy/check", 200, policyRequest.toString())["denied"].boolean.should == true;
    write(policyPath, "rules:\n  - action: screen\n");
    request("/api/policy/check", 503, policyRequest.toString())["denied"].boolean.should == true;
    write(policyPath, `rules:
  - action: screen
    models: []
    questions:
      - type: predicate
        name: inspect
        instructions: Is the request allowed?
`);
    request("/api/policy/check", 503, policyRequest.toString())["denied"].boolean.should == true;

    JSONValue permissionRequest = JSONValue([
        "hook_event_name": JSONValue("PermissionRequest"),
        "session_id": JSONValue("hook-session"),
        "cwd": JSONValue(fixture.root),
        "tool_name": JSONValue("exec"),
        "tool_input": JSONValue(["command": JSONValue("git status")])
    ]);
    JSONValue preToolUse = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("hook-session"),
        "cwd": JSONValue(fixture.root),
        "tool_name": JSONValue("exec"),
        "tool_input": JSONValue(["command": JSONValue("git status")])
    ]);
    JSONValue hookCall = hookSession(fixture, "hook-session");
    write(policyPath, "rules:\n  - action: allow\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString()).should == parseJSON("{}");
    request("/api/hooks/permission-request", 200, permissionRequest.toString()).should == parseJSON("{}");
    write(policyPath, "rules:\n  - action: deny\n    reason: Blocked\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["reason"].str.should == "Blocked";
    write(policyPath, "rules: []\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["reason"].str
        .should == "No policy rule matched";
    finishHookSession(hookCall);
    foreach (id; ["session-0", "session-1", "batch-owned", "batch-other"])
        finishHookSession(hookSession(fixture, id));

    request("/api/health")["status"].str.should == "ok";

    long worker = request("/api/health")["workerPid"].integer;
    string settings = readText(buildPath("/proc", worker.to!string, "environ"));
    settings.canFind("SERVERINO_WORKER_CONFIG_MAX_WORKER_LIFETIME="~Duration.max.total!"msecs".to!string~'\0')
        .should == true;
    settings.canFind("SERVERINO_WORKER_CONFIG_MAX_WORKER_IDLING="~Duration.max.total!"msecs".to!string~'\0')
        .should == true;

    foreach (i; 0..12)
    {
        string name = "agent-"~i.to!string;
        request("/api/profiles", 201, JSONValue(["name": JSONValue(name)]).toString())["name"].str.should == name;
        request(
            "/api/profiles/"~name~"/session",
            200,
            JSONValue(["id": JSONValue("session-"~i.to!string)]).toString()
        )["session"]["id"].str.should == "session-"~i.to!string;
        request("/api/profiles/"~name)["session"]["id"].str.should == "session-"~i.to!string;
    }

    request("/api/profiles").array.length.should == 12;
    request("/api/sessions").array.canFind!(entry => entry["id"].str == "session-0").should == true;
    JSONValue launch = JSONValue([
        "prompt": JSONValue("callback"),
        "directory": JSONValue(fixture.root)
    ]);
    JSONValue started = request("/api/sessions", 202, launch.toString());
    JSONValue startedCall = waitForCall(started);
    startedCall["kind"].str.should == "start";
    startedCall["status"].str.should == "succeeded";
    startedCall["sessionId"].str.should == "created-0";
    readText(buildPath(fixture.root, "callback.txt")).should == "200";
    request("/api/health")["status"].str.should == "ok";
    request("/api/sessions/created-0")["status"].str.should == "offline";
    request("/api/sessions/created-0/log")["log"].str.should == "AUTONOM_READY";
    launch["directory"] = JSONValue(buildPath(fixture.root, "missing"));
    request("/api/sessions", 400, launch.toString());
    launch["directory"] = JSONValue(fixture.root);
    JSONValue printed = request("/api/print", 202, launch.toString());
    waitForCall(printed)["reply"].str.should == "AUTONOM_READY";
    launch["prompt"] = JSONValue("hang");
    JSONValue resumed = request("/api/sessions/session-0/resume", 200, launch.toString());
    ["starting", "online"].canFind(resumed["status"].str).should == true;
    request("/api/sessions/session-0/resume", 409, launch.toString());
    request("/api/profiles/agent-0/session", 409, `{"id":"replacement"}`);
    request("/api/sessions/session-0/stop", 202, "{}");
    waitUntil(delegate bool()
    {
        return request("/api/sessions/session-0")["status"].str == "offline";
    });
    launch["prompt"] = JSONValue("fail");
    request("/api/sessions/session-0/resume", 200, launch.toString());
    waitUntil(delegate bool()
    {
        return request("/api/sessions/session-0")["status"].str == "failed";
    });
    request("/api/profiles/agent-0/session")["exitStatus"].integer.should == 0;
    request("/api/sessions/session-0/log")["log"].str.canFind("fail").should == true;
    JSONValue removedSession = request(
        "/api/sessions/session-0",
        202,
        null,
        "application/json",
        HTTP.Method.del
    );
    waitForCall(removedSession)["status"].str.should == "succeeded";
    request("/api/profiles/agent-0")["session"].should == JSONValue(null);
    request("/api/sessions/session-0/log", 404);
    launch["prompt"] = JSONValue("hang");
    request("/api/sessions/session-1/resume", 200, launch.toString());

    request("/api/sessions/remove", 405)["error"].str.should == "Method not allowed";
    request("/api/sessions/remove", 400, "{}");
    request("/api/sessions/remove", 400, `{"ids":"session-1"}`);
    request("/api/sessions/remove", 400, `{"ids":[42]}`);
    request("/api/sessions/remove", 400, `{"ids":["duplicate","duplicate"]}`);
    request("/api/sessions/remove", 400, `{"ids":[],"unexpected":true}`);
    request("/api/sessions/batch-owned/resume", 200, launch.toString());
    request("/api/sessions/remove", 400, `{"ids":["batch-owned","../escape"]}`);
    ["starting", "online"].canFind(request("/api/sessions/batch-owned")["status"].str).should == true;
    JSONValue ownedRemoval = request("/api/sessions/remove", 202, `{"ids":["batch-owned"]}`);
    waitForCall(request("/api/executions/"~ownedRemoval["executions"][0]["id"].str))
        ["status"].str.should == "succeeded";
    request("/api/sessions/batch-owned/log", 404);
    JSONValue emptyCleanup = request("/api/sessions/remove", 200, `{"ids":[]}`);
    emptyCleanup["executions"].array.length.should == 0;
    request("/api/sessions/batch-other/resume", 200, launch.toString());
    JSONValue cleanup = request("/api/sessions/remove", 202, `{"ids":["missing","batch-other"]}`);
    cleanup["executions"].array.length.should == 2;
    cleanup["failed"].array.length.should == 0;
    JSONValue missing = waitForCall(request(
        "/api/executions/"~cleanup["executions"][0]["id"].str
    ));
    missing["status"].str.should == "failed";
    JSONValue deleted = waitForCall(request(
        "/api/executions/"~cleanup["executions"][1]["id"].str
    ));
    deleted["status"].str.should == "succeeded";
    request("/api/sessions/batch-other/log", 404);

    request("/api/health")["workerPid"].integer.should == worker;

    request("/api/stop", 405)["error"].str.should == "Method not allowed";
    request("/api/stop", 400, "{");
    request(
        "/api/stop",
        400,
        "{}",
        "text/plain"
    );
    request("/api/stop", 400, `{"unexpected":true}`);
    request("/api/health")["status"].str.should == "ok";
    request("/api/stop", 202, "{}")["status"].str.should == "stopping";
    waitUntil(delegate bool()
    {
        return tryWait(daemon.process).terminated;
    });
    wait(daemon.process).should == 0;

    daemon.close();
    daemon = startDaemon(fixture);
    request("/api/profiles").array.length.should == 12;
    request("/api/profiles/agent-0")["session"].should == JSONValue(null);
    request("/api/profiles/agent-1/session")["id"].str.should == "session-1";
    request("/api/profiles/agent-1/session")["status"].str.should == "offline";
    request("/api/stop", 202, "{}");
    waitUntil(delegate bool()
    {
        return tryWait(daemon.process).terminated;
    });
    wait(daemon.process).should == 0;
    foreach (event, groups; hooks.object)
        parseJSON(invokeHook(groups[0]["hooks"][0]["command"].str,
            JSONValue(["hook_event_name": JSONValue(event)]))).should == parseJSON("{}");
}

