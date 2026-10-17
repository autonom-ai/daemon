module tests.http.desktop;

import daemon.interop.process : createProcessGroup, terminate;
import tests.common;
import tests.http.common;
import tests.interop.acp.common : LineCollector;

import unit_threaded;

import core.thread : Thread;
import core.time : seconds;
import std.file : readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath;
import std.process;

@Name("Desktop forwarding restores peer IDs and shares native and HTTP permission settlement") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit) daemon.close();
    write(buildPath(fixture.root, "next-session-id"), "desktop-session");
    Config options = Config.newEnv;
    options.preExecFunction = &createProcessGroup;
    ProcessPipes relay = pipeProcess(
        ["bin/autonom-acp", "--devin", fixture.config.devinCommand, "--config", fixture.path],
        Redirect.stdin | Redirect.stdout, ["AUTONOM_PORT": "18080"], options);
    LineCollector frames = new LineCollector();
    Thread reader = new Thread({ frames.pump(relay.stdout); });
    reader.start();
    scope(exit)
    {
        relay.stdin.close();
        terminate(relay.pid, 1.seconds);
        reader.join();
    }
    void send(JSONValue value)
    {
        relay.stdin.writeln(value.toString());
        relay.stdin.flush();
    }
    JSONValue find(string method, JSONValue identity = JSONValue(null))
    {
        JSONValue ret = JSONValue(null);
        foreach (line; frames.snapshot())
        {
            JSONValue frame = parseJSON(line);
            if (method.length && "method" in frame.object && frame["method"].str == method)
                ret = frame;
            else if (!method.length && "id" in frame.object && frame["id"] == identity &&
                ("result" in frame.object || "error" in frame.object))
                ret = frame;
        }
        return ret;
    }
    send(parseJSON(`{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}`));
    waitUntil(delegate bool() { return !find(null, JSONValue("1")).isNull; });
    send(JSONValue([
        "jsonrpc": JSONValue("2.0"), "id": JSONValue(1), "method": JSONValue("session/new"),
        "params": JSONValue(["cwd": JSONValue(fixture.root), "mcpServers": JSONValue.emptyArray])
    ]));
    waitUntil(delegate bool() { return !find(null, JSONValue(1)).isNull; });
    find(null, JSONValue(1))["result"]["sessionId"].str.should == "desktop-session";
    send(parseJSON(`{"jsonrpc":"2.0","id":"autonom:1","method":"session/prompt","params":{"sessionId":"desktop-session","prompt":[{"type":"text","text":"permission"}]}}`));
    JSONValue native;
    waitUntil(delegate bool()
    {
        native = find("session/request_permission");
        return !native.isNull;
    });
    string path = "/api/sessions/desktop-session/permissions";
    JSONValue pending = request(path);
    pending.array.length.should == 1;
    pending[0]["id"].should == native["id"];
    JSONValue decision = JSONValue(["id": pending[0]["id"], "optionId": pending[0]["options"][0]["optionId"]]);
    request(path, 200, decision.toString());
    request(path, 409, decision.toString());
    waitUntil(delegate bool() { return !find(null, JSONValue("autonom:1")).isNull; });
    // A late native answer must not be forwarded or matched to another request.
    send(JSONValue([
        "jsonrpc": JSONValue("2.0"), "id": native["id"],
        "result": JSONValue(["outcome": JSONValue([
            "outcome": JSONValue("selected"), "optionId": decision["optionId"]
        ])])
    ]));
    request(path).array.length.should == 0;

    send(parseJSON(`{"jsonrpc":"2.0","id":"native","method":"session/prompt","params":{"sessionId":"desktop-session","prompt":[{"type":"text","text":"permission"}]}}`));
    JSONValue previous = native["id"];
    waitUntil(delegate bool()
    {
        native = find("session/request_permission");
        return native["id"] != previous;
    });
    send(JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "id": native["id"],
        "result": JSONValue(["outcome": JSONValue([
            "outcome": JSONValue("selected"),
            "optionId": JSONValue("reject_once")
        ])])
    ]));
    waitUntil(delegate bool() { return !find(null, JSONValue("native")).isNull; });
    decision["id"] = native["id"];
    request(path, 409, decision.toString());
    request(path).array.length.should == 0;

    string capability = readText(buildPath(fixture.config.dataDir, "mcp", "desktop-session.token"));
    daemon.close();
    send(parseJSON(`{"jsonrpc":"2.0","id":"offline","method":"session/prompt","params":{"sessionId":"desktop-session","prompt":[{"type":"text","text":"offline"}]}}`));
    waitUntil(delegate bool() { return !find(null, JSONValue("offline")).isNull; }, 1.seconds);

    daemon = startDaemon(fixture);
    waitUntil(delegate bool()
    {
        try
        {
            return request("/api/mcp/session", 200, null, "application/json", HTTP.Method.undefined,
                null, null, false, capability)["id"].str == "desktop-session";
        }
        catch (Exception)
            return false;
    }, 15.seconds);
    readText(buildPath(fixture.config.dataDir, "mcp", "desktop-session.token")).should == capability;

    relay.stdin.close();
    waitUntil(delegate bool() { return tryWait(relay.pid).terminated; });
    request("/api/mcp/session", 403, null, "application/json", HTTP.Method.undefined,
        null, null, false, capability);
}
