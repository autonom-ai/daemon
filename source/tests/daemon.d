module tests.daemon;

import autonom.daemon.server : health, stop;
import tests.common : Fixture, waitUntil;
import serverino : endpoint, route;
import unit_threaded : Name, Serial, should;

import core.time : Duration, seconds;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : readText, write;
import std.json : JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;
import std.path : buildPath;
import std.process : Pid, kill, spawnProcess, tryWait, wait;
import std.stdio : File, stdin;
import std.traits : hasUDA;

private:

JSONValue request(
    string path,
    uint status = 200,
    string data = null,
    string contentType = "application/json"
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 2.seconds;
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

    string log = buildPath(fixture.root, "daemon.log");
    File output = File(log, "w");
    scope(exit)
        output.close();

    Pid process = spawnProcess(
        ["bin/autonom-http-test"],
        stdin,
        output,
        output,
        ["AUTONOM_TEST_CONFIG": fixture.path]
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
}
