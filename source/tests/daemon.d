module tests.daemon;

import daemon.server : health, stop;
import tests.common;
import serverino : endpoint, route;
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
import std.traits : hasUDA;

private:

struct RunningDaemon
{
    Pid process;
    File log;

    void close()
    {
        if (process !is null)
        {
            if (!tryWait(process).terminated)
            {
                kill(process);
                wait(process);
            }

            process = null;
        }

        if (log.isOpen)
            log.close();
    }
}

RunningDaemon startDaemon(Fixture fixture)
{
    requestToken = fixture.bridge.access.clientToken;
    hookTokens = null;
    RunningDaemon ret;
    string path = buildPath(fixture.root, "daemon.log");
    ret.log = File(path, "w");
    ret.process = spawnProcess(
        ["bin/autonom-daemon"],
        stdin,
        ret.log,
        ret.log,
        ["AUTONOM_CONFIG": fixture.path, "AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    );
    waitUntil(delegate bool()
    {
        if (tryWait(ret.process).terminated)
            throw new Exception(readText(path));

        try
            return request("/api/health")["pid"].integer == ret.process.processID;
        catch (CurlException)
            return false;
    });
    return ret;
}

string invokeHook(string command, JSONValue payload, int expected = 0)
{
    File input = File.tmpfile();
    File output = File.tmpfile();
    File errors = File.tmpfile();
    scope(exit)
    {
        input.close();
        output.close();
        errors.close();
    }

    input.write(payload.toString());
    input.rewind();
    int status = wait(spawnProcess(
        ["/bin/sh", "-c", command],
        input,
        output,
        errors,
        ["AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    ));
    errors.rewind();
    if (status != expected)
        throw new Exception(cast(string)errors.byChunk(4096).join);

    output.rewind();
    return cast(string)output.byChunk(4096).join;
}

JSONValue hookSession(
    Fixture fixture,
    string id,
    string profile = null,
    bool identify = true
)
{
    if (!exists(fixture.config.devinCommand))
        installFake(fixture);

    write(buildPath(fixture.root, "next-session-id"), id);
    JSONValue ret = request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue("auth:"~id),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue(profile.length ? profile : "")
    ]).toString());
    string tokenPath = buildPath(fixture.root, id~".token");
    waitUntil(delegate bool()
    {
        return exists(tokenPath);
    });
    hookTokens[id] = readText(tokenPath);
    if (identify)
    {
        request("/api/hooks/session-start", 200, JSONValue([
            "hook_event_name": JSONValue("SessionStart"),
            "session_id": JSONValue(id)
        ]).toString());
    }

    return ret;
}

void finishHookSession(JSONValue execution)
{
    request("/api/executions/"~execution["id"].str~"/stop", 202, "{}");
    waitForExecution(execution);
}

JSONValue waitForExecution(JSONValue accepted)
{
    string path = "/api/executions/"~accepted["id"].str;
    JSONValue ret;
    waitUntil(delegate bool()
    {
        ret = request(path);
        return ret["status"].str != "running" && ret["status"].str != "stopping";
    });
    return ret;
}

public:

@Name("Daemon declares health and stop HTTP endpoints")
unittest
{
    static foreach (HANDLER; ["health", "stop"])
    {
        hasUDA!(mixin(HANDLER), endpoint).should == true;
        hasUDA!(mixin(HANDLER), route).should == true;
    }
}

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
        hook["timeout"].integer.should == (event == "PermissionRequest" ? 250 : 20);
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
    JSONValue hookExecution = hookSession(fixture, "hook-session");
    write(policyPath, "rules:\n  - action: allow\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString()).should == parseJSON("{}");
    JSONValue permission = request("/api/hooks/permission-request", 200, permissionRequest.toString());
    string permissionPath = "/api/permissions/"~permission["permission"].str;
    request(permissionPath)["decision"].str.should == "";
    request(permissionPath, 200, `{"decision":"approve"}`)["decision"].str.should == "approve";
    write(policyPath, "rules:\n  - action: deny\n    reason: Blocked\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["reason"].str.should == "Blocked";
    write(policyPath, "rules: []\n");
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, preToolUse.toString())["reason"].str
        .should == "No policy rule matched";
    finishHookSession(hookExecution);
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
    request("/api/sessions").array.canFind(JSONValue("session-0")).should == true;
    JSONValue launch = JSONValue([
        "prompt": JSONValue("callback"),
        "directory": JSONValue(fixture.root)
    ]);
    JSONValue started = request("/api/sessions", 202, launch.toString());
    JSONValue startedExecution = waitForExecution(started);
    startedExecution["kind"].str.should == "start";
    startedExecution["status"].str.should == "succeeded";
    startedExecution["sessionId"].str.should == "created-0";
    readText(buildPath(fixture.root, "callback.txt")).should == "200";
    request("/api/health")["status"].str.should == "ok";
    request("/api/sessions/created-0")["status"].str.should == "offline";
    request("/api/sessions/created-0/log")["log"].str.should == "AUTONOM_READY";
    launch["directory"] = JSONValue(buildPath(fixture.root, "missing"));
    request("/api/sessions", 400, launch.toString());
    launch["directory"] = JSONValue(fixture.root);
    JSONValue printed = request("/api/print", 202, launch.toString());
    waitForExecution(printed)["reply"].str.should == "AUTONOM_READY";
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
    waitForExecution(removedSession)["status"].str.should == "succeeded";
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
    waitForExecution(request("/api/executions/"~ownedRemoval["executions"][0]["id"].str))
        ["status"].str.should == "succeeded";
    request("/api/sessions/batch-owned/log", 404);
    JSONValue emptyCleanup = request("/api/sessions/remove", 200, `{"ids":[]}`);
    emptyCleanup["executions"].array.length.should == 0;
    request("/api/sessions/batch-other/resume", 200, launch.toString());
    JSONValue cleanup = request("/api/sessions/remove", 202, `{"ids":["missing","batch-other"]}`);
    cleanup["executions"].array.length.should == 2;
    cleanup["failed"].array.length.should == 0;
    JSONValue missing = waitForExecution(request(
        "/api/executions/"~cleanup["executions"][0]["id"].str
    ));
    missing["status"].str.should == "failed";
    JSONValue deleted = waitForExecution(request(
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

@Name("Daemon coordinates rooms, messages, and the event gate") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    static foreach (name; ["marlow", "wren"])
        request("/api/profiles", 201, JSONValue(["name": JSONValue(name)]).toString());
    request("/api/profiles", 409, `{"name":"human"}`);
    request("/api/profiles/marlow/session", 200, `{"id":"session-1"}`);
    request("/api/profiles/wren/session", 200, `{"id":"session-2"}`);

    request("/api/rooms").array.length.should == 0;
    request("/api/rooms?session=missing", 409)["error"].str.should == "No profile is registered for this session";
    request("/api/rooms?session=session-1", 400, `{"name":"general","extra":true}`);
    JSONValue created = request("/api/rooms?session=session-1", 201, `{"name":"#General"}`);
    created["name"].str.should == "general";
    created["count"].integer.should == 0;
    created["lastTs"].should == JSONValue(null);
    request("/api/rooms?session=session-2").array.length.should == 1;
    request("/api/rooms/general?session=session-2")["unread"].integer.should == 0;

    JSONValue posted = request(
        "/api/rooms/general/messages?session=session-1",
        201,
        `{"text":"hello","ping":["wren"]}`
    );
    posted["from"].str.should == "marlow";
    posted["room"].str.should == "general";
    posted["pinged"].array[0].str.should == "wren";
    JSONValue read = request("/api/rooms/general/messages?session=session-2");
    read["source"].str.should == "room";
    read["room"].str.should == "general";
    read["messages"].array.length.should == 1;
    read["messages"].array[0]["text"].str.should == "hello";
    request("/api/rooms/general/messages?session=session-2")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 1;
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=dms")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=bad", 400);
    request("/api/messages?session=session-2", 404, `{"to":"missing","text":"hi"}`);

    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, "session-2.lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }

    flock(lock.fileno, LOCK_EX).should == 0;
    hookSession(fixture, "session-2");
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    write(buildPath(fixture.root, ".devin", "policy.yml"), "rules:\n  - action: allow\n");
    JSONValue gate = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("session-2"),
        "tool_name": JSONValue("mcp__autonom-coord__read_events"),
        "tool_input": JSONValue.emptyObject
    ]);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    gate["tool_name"] = JSONValue("exec");
    request("/api/hooks/pre-tool-use", 200, gate.toString()).object.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__post_message");
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";

    request("/api/messages?session=session-1", 201, `{"to":"wren","text":"ping","ping":["wren"]}`);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, gate.toString())["reason"].str
        .should == "You have unread events - read them first: call read_events";
    JSONValue context = JSONValue([
        "hook_event_name": JSONValue("UserPromptSubmit"),
        "session_id": JSONValue("session-2"),
        "prompt": JSONValue("continue")
    ]);
    request("/api/hooks/user-prompt-submit", 200, context.toString())["hookSpecificOutput"]["additionalContext"].str
        .should == "You have 1 unread event - read them with read_events: ping from marlow.";
    context["hook_event_name"] = JSONValue("PostToolUse");
    context["tool_name"] = JSONValue("exec");
    context["tool_input"] = JSONValue(["command": JSONValue("git status")]);
    request("/api/hooks/post-tool-use", 200, context.toString())["hookSpecificOutput"]["additionalContext"].str
        .should == "You have 1 unread event - read them with read_events: ping from marlow.";
    context["session_id"] = JSONValue("session-1");
    request("/api/hooks/post-tool-use", 200, context.toString()).object.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__read_messages");
    gate["tool_input"] = JSONValue(["source": JSONValue("pings")]);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["decision"].str.should == "block";
    gate["tool_name"] = JSONValue("mcp__autonom-coord__read_events");
    gate["tool_input"] = JSONValue.emptyObject;
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    JSONValue pending = request("/api/events?session=session-2");
    pending["events"].array.length.should == 1;
    pending["events"].array[0]["type"].str.should == "ping";
    pending["events"].array[0]["text"].str.should == "ping";
    pending["events"].array[0]["schedule"].should == JSONValue(null);
    request("/api/events?session=session-2")["events"].array.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__post_message");
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";

    request("/api/messages?session=session-1", 201, `{"to":"wren","text":"again","ping":["wren"]}`);
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 2;
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    request("/api/rooms/general/messages?session=session-1", 201, `{"text":"no pings"}`)["pinged"].array.length
        .should == 0;

    request("/api/rooms/general/membership?session=session-2")["owner"].str.should == "marlow";
    request("/api/rooms/general/membership?session=session-2")["involved"].should == JSONValue(null);
    request("/api/rooms/general/membership?session=session-2", 404, `{"involved":["marlow"]}`);
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":["marlow"]}`)["involved"].array.length
        .should == 1;
    request("/api/rooms?session=session-2").array.length.should == 0;
    request("/api/rooms/general?session=session-2", 404);
    request("/api/rooms/general/messages?session=session-2", 404);
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":[]}`)["involved"].array.length
        .should == 0;
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":null}`)["involved"]
        .should == JSONValue(null);

    request("/api/rooms/general/admins?session=session-2", 404, `{"profile":"wren"}`);
    request(
        "/api/rooms/general/admins?session=session-1",
        200,
        `{"profile":"wren"}`
    )["admins"].array.length.should == 1;
    request(
        "/api/rooms/general/admins?session=session-1&profile=wren",
        200,
        null,
        "application/json",
        HTTP.Method.del
    )["admins"].array.length.should == 0;
    request("/api/rooms/general/admins?session=session-1", 404, `{"profile":"missing"}`);

    request("/api/rooms/general?session=session-2", 404, null, "application/json", HTTP.Method.del);
    request("/api/rooms/general?session=session-1", 200, null, "application/json", HTTP.Method.del)["name"].str
        .should == "general";
    request("/api/rooms?session=session-1").array.length.should == 0;
}

@Name("Daemon schedules wakes and reads events") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    static foreach (name; ["marlow", "wren"])
        request("/api/profiles", 201, JSONValue(["name": JSONValue(name)]).toString());
    request("/api/profiles/marlow/session", 200, `{"id":"session-1"}`);
    request("/api/profiles/wren/session", 200, `{"id":"session-2"}`);

    request("/api/schedules").array.length.should == 0;
    request("/api/schedules?session=missing", 409);
    request("/api/schedules?session=session-1", 405, null, "application/json", HTTP.Method.del);
    request("/api/schedules?session=session-1", 400, `{"type":"unknown"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","at":"nope"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","at":"2020-01-01T00:00:00Z"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","every":0}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","every":10,"at":"2030-01-01T00:00:00Z"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"room"}`);
    request("/api/schedules?session=session-1", 404, `{"type":"room","room":"missing"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","from":"missing"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","room":"general"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","unknown":true}`);
    request("/api/events")["events"].array.length.should == 0;
    request("/api/events?session=missing", 409);
    request("/api/events?session=session-2", 405, "{}", "application/json", HTTP.Method.post);

    JSONValue created = request("/api/schedules?session=session-1", 201, `{"type":"ping","from":"wren"}`);
    created["type"].str.should == "ping";
    created["from"].str.should == "wren";
    created["room"].should == JSONValue(null);
    created["every"].should == JSONValue(null);
    request("/api/schedules?session=session-1").array.length.should == 1;
    request("/api/schedules?session=session-2").array.length.should == 0;
    request("/api/schedules?session=session-1", 400, `{"type":"ping","from":"wren","extra":true}`);
    request("/api/schedules/refresh", 400, "{");
    request("/api/schedules/refresh", 400, `{"unexpected":true}`);
    request("/api/schedules/refresh", 200, "{}").should == parseJSON("{}");
    request("/api/events?session=session-2")["events"].array.length.should == 0;

    request("/api/messages?session=session-2", 201, `{"to":"marlow","text":"scheduled","ping":["marlow"]}`);
    JSONValue scheduled = request("/api/events?session=session-1");
    scheduled["events"].array.length.should == 1;
    scheduled["events"].array[0]["type"].str.should == "ping";
    scheduled["events"].array[0]["schedule"].str.should == created["id"].str;

    request(
        "/api/schedules/"~created["id"].str~"?session=session-1",
        200,
        null,
        "application/json",
        HTTP.Method.del
    )["id"].str.should == created["id"].str;
    request("/api/schedules/"~created["id"].str~"?session=session-1", 404, null, "application/json", HTTP.Method.del);
    request("/api/schedules?session=session-1").array.length.should == 0;

    JSONValue clock = request("/api/schedules?session=session-1", 201, `{"type":"clock","every":1}`);
    clock["every"].integer.should == 1;
    (clock["next"].integer > 0).should == true;
    Thread.sleep(1100.msecs);
    request("/api/schedules/refresh", 200, "{}");
    request(
        "/api/schedules/"~clock["id"].str~"?session=session-1",
        200,
        null,
        "application/json",
        HTTP.Method.del
    );
    JSONValue fired = request("/api/events?session=session-1");
    (fired["events"].array.length >= 1).should == true;
    fired["events"].array[0]["type"].str.should == "clock";
    fired["events"].array[0]["text"].str.should == "scheduled wake, repeats every 1s";
    request("/api/events?session=session-1")["events"].array.length.should == 0;
}

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
    request("/api/client/state")["profiles"].array[0]["managed"].boolean.should == true;
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

@Name("Human chat uses its own cursors and can DM, ping, and participate in rooms") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    hookSession(fixture, "managed-one");
    request("/api/profiles", 201, `{"name":"alpha"}`);
    request("/api/profiles/alpha/session", 200, `{"id":"managed-one"}`);
    request("/api/rooms", 201, `{"name":"team"}`);
    request("/api/rooms/team/messages", 201, `{"text":"human check-in","ping":["alpha"]}`)["from"].str
        .should == "human";
    request("/api/client/messages?source=room&target=team").array.length.should == 1;
    request("/api/rooms/team/messages?session=managed-one")["messages"].array.length.should == 1;
    request("/api/messages", 201, `{"to":"alpha","text":"direct from human"}`);
    request("/api/messages?session=managed-one", 201, `{"to":"human","text":"direct from alpha","ping":["human"]}`);
    JSONValue direct = request("/api/client/messages?source=dm&target=alpha");
    direct.array.length.should == 2;
    direct[0]["from"].str.should == "human";
    direct[1]["from"].str.should == "alpha";
    request("/api/client/messages?source=pings").array.length.should == 1;
    request("/api/client/state")["humanEvents"].integer.should == 0;
    request("/api/client/events?profile=alpha").array.length.should == 1;
    request("/api/messages?session=managed-one&source=dms")["messages"].array.length.should == 1;
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
        request("/api/client/state")["profiles"][0]["session"]["id"].str.should == "managed-second";

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
