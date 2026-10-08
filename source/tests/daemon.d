module tests.daemon;

import autonom.server : health, stop;
import tests.common : Fixture, waitUntil;
import serverino : endpoint, route;
import unit_threaded : Name, Serial, should;

import core.time : Duration, seconds;
import std.algorithm : canFind;
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
    list) printf '[{"id":"session-0"}]'; exit 0 ;;
    rm) [ "$4" = missing ] && exit 1; exit 0 ;;
    --print) printf 'AUTONOM_READY'; exit 0 ;;
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
    write(policyPath, "rules:\n  - action: screen\n    question: Is it harmful?\n");
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
    request("/api/print", 200, launch.toString())["reply"].str.should == "AUTONOM_READY";
    request("/api/sessions/session-0/start", 200, launch.toString())["status"].str.should == "starting";
    request("/api/sessions/session-0/start", 400, launch.toString());
    request("/api/profiles/agent-0/session", 409, `{"id":"replacement"}`);
    request("/api/sessions/session-0/stop", 200, "{}")["status"].str.should == "offline";
    launch["prompt"] = JSONValue("fail");
    request("/api/sessions/session-0/start", 200, launch.toString());
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
    request("/api/sessions/session-1/start", 200, launch.toString());

    request("/api/sessions/remove", 405)["error"].str.should == "Method not allowed";
    request("/api/sessions/remove", 400, "{}");
    request("/api/sessions/remove", 400, `{"ids":"session-1"}`);
    request("/api/sessions/remove", 400, `{"ids":[42]}`);
    request("/api/sessions/remove", 400, `{"ids":["duplicate","duplicate"]}`);
    request("/api/sessions/remove", 400, `{"ids":[],"unexpected":true}`);
    request("/api/sessions/batch-owned/start", 200, launch.toString());
    request("/api/sessions/remove", 400, `{"ids":["batch-owned","../escape"]}`);
    request("/api/sessions/batch-owned")["status"].str.should == "starting";
    request("/api/sessions/remove", 200, `{"ids":["batch-owned"]}`)["removed"].array.should ==
        [JSONValue("batch-owned")];
    request("/api/sessions/batch-owned/log", 404);
    request("/api/sessions/remove", 200, `{"ids":[]}`)["removed"].array.length.should == 0;
    request("/api/sessions/batch-other/start", 200, launch.toString());
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
}
