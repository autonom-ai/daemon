module tests.daemon;

import autonom.server : health, stop;
import tests.common : Fixture, waitUntil;
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
import std.process : Config, Pid, kill, spawnProcess, tryWait, wait;
import std.stdio : File, stdin;
import std.traits : hasUDA;

private:

JSONValue request(
    string path,
    uint status = 200,
    string data = null,
    string contentType = "application/json",
    HTTP.Method method = HTTP.Method.undefined
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 2.seconds;
    client.method = method;
    if (data !is null)
        client.setPostData(data, contentType);

    string body;
    client.onReceive = (ubyte[] chunk)
    {
        body ~= cast(char[])chunk;
        return chunk.length;
    };
    client.perform();
    client.statusLine.code.should == status;
    return parseJSON(body);
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
        echo "created-$count" >> "$(dirname "$0")/sessions.txt"
        printf 'AUTONOM_READY'; exit 0 ;;
esac
for argument do prompt="$argument"; done
printf '%s\n' "$prompt"
[ "$prompt" = fail ] && exit 7
trap 'exit 0' TERM
while :; do sleep 0.05; done
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
    write(fixture.path, readText(fixture.path)~"policyUrl: http://127.0.0.1:1\npolicyModel: test-model\n");
    string log = buildPath(fixture.root, "daemon.log");
    File output = File(log, "w");
    scope(exit)
        output.close();

    Pid process = spawnProcess(
        ["bin/autonom-daemon"],
        stdin,
        output,
        output,
        ["AUTONOM_CONFIG": fixture.path, "AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    );
    scope(exit)
    {
        if (!tryWait(process).terminated)
        {
            kill(process);
            wait(process);
        }
    }

    waitUntil(delegate bool()
    {
        enforce(!tryWait(process).terminated, readText(log));
        try
            return request("/api/health")["status"].str == "ok";
        catch (CurlException)
            return false;
    });
    request("/api/health")["pid"].integer.should == process.processID;
    request("/api/health", 405, "{}")["error"].str.should == "Method not allowed";

    JSONValue hooks = parseJSON(readText(".devin/hooks.v1.json"));
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
        hook["timeout"].integer.should == 6;
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
    questions:
      - type: predicate
        name: inspect
        instructions: Is the request allowed?
`);
    request("/api/policy/check", 503, policyRequest.toString())["denied"].boolean.should == true;
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
        "prompt": JSONValue("work"),
        "directory": JSONValue(fixture.root)
    ]);
    JSONValue started = request("/api/sessions", 201, launch.toString());
    started["id"].str.should == "created-0";
    started["status"].str.should == "offline";
    request("/api/sessions/created-0/log")["log"].str.should == "AUTONOM_READY";
    launch["directory"] = JSONValue(buildPath(fixture.root, "missing"));
    request("/api/sessions", 400, launch.toString());
    launch["directory"] = JSONValue(fixture.root);
    request("/api/print", 200, launch.toString())["reply"].str.should == "AUTONOM_READY";
    request("/api/sessions/session-0/resume", 200, launch.toString())["status"].str.should == "starting";
    request("/api/sessions/session-0/resume", 400, launch.toString());
    request("/api/profiles/agent-0/session", 409, `{"id":"replacement"}`);
    request("/api/sessions/session-0/stop", 200, "{}")["status"].str.should == "offline";
    launch["prompt"] = JSONValue("fail");
    request("/api/sessions/session-0/resume", 200, launch.toString());
    waitUntil(delegate bool()
    {
        return request("/api/sessions/session-0")["status"].str == "failed";
    });
    request("/api/profiles/agent-0/session")["exitStatus"].integer.should == 7;
    request("/api/sessions/session-0/log")["log"].str.canFind("fail").should == true;
    request(
        "/api/sessions/session-0",
        200,
        null,
        "application/json",
        HTTP.Method.del
    );
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
    request("/api/sessions/remove", 200, `{"ids":["batch-owned"]}`)["removed"].array.should ==
        [JSONValue("batch-owned")];
    request("/api/sessions/batch-owned/log", 404);
    request("/api/sessions/remove", 200, `{"ids":[]}`)["removed"].array.length.should == 0;
    request("/api/sessions/batch-other/resume", 200, launch.toString());
    JSONValue cleanup = request("/api/sessions/remove", 503, `{"ids":["missing","batch-other"]}`);
    cleanup["removed"].array.should == [JSONValue("batch-other")];
    cleanup["failed"].array.should == [JSONValue("missing")];
    request("/api/sessions/batch-other/log", 404);

    JSONValue configuration = request("/api/config");
    write(fixture.path, "dataDir: changed\nsessionLockDir: locks\ndevinCommand: ./devin\n");
    request("/api/config").should == configuration;
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
        return tryWait(process).terminated;
    });
    wait(process).should == 0;

    write(fixture.path, "dataDir: data\nsessionLockDir: locks\ndevinCommand: ./devin\n");
    process = spawnProcess(
        ["bin/autonom-daemon"],
        stdin,
        output,
        output,
        ["AUTONOM_CONFIG": fixture.path, "AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    );
    waitUntil(delegate bool()
    {
        enforce(!tryWait(process).terminated, readText(log));
        try
            return request("/api/health")["status"].str == "ok";
        catch (CurlException)
            return false;
    });
    request("/api/profiles").array.length.should == 12;
    request("/api/profiles/agent-0")["session"].should == JSONValue(null);
    request("/api/profiles/agent-1/session")["id"].str.should == "session-1";
    request("/api/profiles/agent-1/session")["status"].str.should == "offline";
    request("/api/stop", 202, "{}");
    waitUntil(delegate bool()
    {
        return tryWait(process).terminated;
    });
    wait(process).should == 0;
    foreach (event, groups; hooks.object)
        invokeHook(groups[0]["hooks"][0]["command"].str,
            JSONValue(["hook_event_name": JSONValue(event)]), 7).should == "";
}
