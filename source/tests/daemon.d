module tests.daemon;

import autonom.server : health, stop;
import tests.common;
import serverino : endpoint, route;
import unit_threaded : Name, Serial, should;

import core.time : Duration, seconds;
import std.algorithm : canFind;
import std.array : join, replicate;
import std.conv : octal, to;
import std.exception : enforce;
import std.file : mkdirRecurse, readText, setAttributes, write;
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
        enforce(!tryWait(ret.process).terminated, readText(path));
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
    enforce(status == expected, cast(string)errors.byChunk(4096).join);
    output.rewind();
    return cast(string)output.byChunk(4096).join;
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

    write(fixture.config.devinCommand, `#!/bin/sh
export_path=
previous=
for argument do
    if [ "$previous" = --export ]; then export_path=$argument; fi
    prompt=$argument
    previous=$argument
done
case "$1" in
    list)
        if [ -f "$(dirname "$0")/sessions.txt" ]; then
            printf '['
            separator=
            while read id; do
                printf '%s{"id":"%s"}' "$separator" "$id"
                separator=,
            done < "$(dirname "$0")/sessions.txt"
            printf ']'
        else
            printf '[{"id":"session-0"}]'
        fi
        exit 0 ;;
    rm) [ "$4" = missing ] && exit 1; exit 0 ;;
    --print)
        count=0
        [ -f "$(dirname "$0")/sessions.txt" ] && count=$(wc -l < "$(dirname "$0")/sessions.txt")
        session_id="created-$count"
        if [ "$prompt" = callback ]; then
            status=$(curl -qfsS -m 1 -x '' -o /dev/null -w '%{http_code}' --json \
                '{"hook_event_name":"SessionStart"}' \
                "http://127.0.0.1:${AUTONOM_PORT:-8080}/api/hooks/session-start") || exit 9
            printf '%s' "$status" > "$(dirname "$0")/callback.txt"
            sleep 0.1
        fi
        echo "$session_id" >> "$(dirname "$0")/sessions.txt"
        printf '{"session_id":"%s"}' "$session_id" > "$export_path"
        printf 'AUTONOM_READY'; exit 0 ;;
esac
for argument do prompt="$argument"; done
printf '%s\n' "$prompt"
[ "$prompt" = fail ] && exit 7
trap 'exit 0' TERM
while :; do sleep 0.05; done
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
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
        request(endpoint, 400, payload.toString());
        payload.object.remove("large");

        hooks[event].array.length.should == 1;
        hooks[event][0]["matcher"].str.should == "";
        hooks[event][0]["hooks"].array.length.should == 1;
        JSONValue hook = hooks[event][0]["hooks"][0];
        hook["type"].str.should == "command";
        hook["timeout"].integer.should == (event == "PreToolUse" ? 12 : 6);
        hook["command"].str.canFind(endpoint).should == true;
        parseJSON(invokeHook(hook["command"].str, payload)).should == parseJSON("{}");
        invokeHook(hook["command"].str, parseJSON("{}"), 22).should == "";
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

    JSONValue hookRequest = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "cwd": JSONValue(fixture.root),
        "tool_name": JSONValue("exec"),
        "tool_input": JSONValue(["command": JSONValue("git status")])
    ]);
    write(policyPath, "rules:\n  - action: allow\n");
    request("/api/hooks/pre-tool-use", 200, hookRequest.toString()).should == parseJSON("{}");
    write(policyPath, "rules:\n  - action: deny\n    reason: Blocked\n");
    request("/api/hooks/pre-tool-use", 200, hookRequest.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, hookRequest.toString())["reason"].str.should == "Blocked";
    write(policyPath, "rules: []\n");
    request("/api/hooks/pre-tool-use", 200, hookRequest.toString())["decision"].str.should == "block";
    request("/api/hooks/pre-tool-use", 200, hookRequest.toString())["reason"].str.should == "No policy rule matched";
    parseJSON(invokeHook(hooks["PreToolUse"][0]["hooks"][0]["command"].str, hookRequest))["decision"].str
        .should == "block";

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
    request("/api/sessions").array[0].str.should == "session-0";
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
    request("/api/sessions/session-0/resume", 200, launch.toString())["status"].str.should == "starting";
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
    request("/api/profiles/agent-0/session")["exitStatus"].integer.should == 7;
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
    launch["prompt"] = JSONValue("work");
    request("/api/sessions/session-1/resume", 200, launch.toString());

    request("/api/sessions/remove", 405)["error"].str.should == "Method not allowed";
    request("/api/sessions/remove", 400, "{}");
    request("/api/sessions/remove", 400, `{"ids":"session-1"}`);
    request("/api/sessions/remove", 400, `{"ids":[42]}`);
    request("/api/sessions/remove", 400, `{"ids":["duplicate","duplicate"]}`);
    request("/api/sessions/remove", 400, `{"ids":[],"unexpected":true}`);
    request("/api/sessions/batch-owned/resume", 200, launch.toString());
    request("/api/sessions/remove", 400, `{"ids":["batch-owned","../escape"]}`);
    request("/api/sessions/batch-owned")["status"].str.should == "starting";
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
        invokeHook(groups[0]["hooks"][0]["command"].str,
            JSONValue(["hook_event_name": JSONValue(event)]), 7).should == "";
}

@Name("Daemon coordinates rooms, messages, and the ping gate") @Serial
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

    request("/api/rooms", 400);
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

    JSONValue gate = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("session-2"),
        "tool_name": JSONValue("mcp__autonom-coord__read_messages"),
        "tool_input": JSONValue(["source": JSONValue("dms")])
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
    gate["tool_name"] = JSONValue("mcp__autonom-coord__read_messages");
    gate["tool_input"] = JSONValue(["source": JSONValue("pings")]);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 1;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__post_message");
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
