module tests.http.wakes;

import daemon.interop.acp : AcpClient;
import tests.common;
import tests.events.common : promptTexts;
import tests.http.common;
import tests.interop.acp.common : agentEnvironment;

import unit_threaded : Name, Serial, should;

import core.thread : Thread;
import core.time : seconds;
import std.algorithm : count;
import std.datetime : Clock, UTC;
import std.file : getcwd, readText;
import std.json : JSONValue;
import std.net.curl : HTTP;
import std.path : buildPath;

@Name("Concurrent HTTP wakes reuse an idle Desktop connection and preserve native human waits") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();
    string[string] environment = agentEnvironment(fixture);
    environment["AUTONOM_PORT"] = "18080";
    environment["XDG_CONFIG_HOME"] = buildPath(fixture.root, "xdg-config");
    AcpClient peer = new AcpClient([buildPath(getcwd(), "bin", "autonom"), "acp", "--config", fixture.path,
        "--devin", fixture.config.devinCommand], environment, fixture.root);
    scope(exit)
        peer.close();
    peer.request("initialize", JSONValue([
        "protocolVersion": JSONValue(1), "clientCapabilities": JSONValue.emptyObject
    ]), 10.seconds);
    string id = peer.request("session/new", JSONValue([
        "cwd": JSONValue(fixture.root), "mcpServers": JSONValue.emptyArray
    ]), 10.seconds)["sessionId"].str;
    request("/api/profiles", 201, `{"name":"target"}`);
    request("/api/profiles/target/session", 200, JSONValue(["id": JSONValue(id)]).toString());
    string sessionPath = "/api/sessions/"~id;
    request(sessionPath)["status"].str.should == "online";
    waitUntil(delegate bool() {
        return request(sessionPath)["activity"].str == "idle";
    });

    // Both requests reach the one production HTTP worker; neither may fork a new CLI.
    string token = readText(buildPath(fixture.config.dataDir, "client.token"));
    void fire()
    {
        HTTP client = HTTP("http://127.0.0.1:18080/api/rooms/general/messages");
        client.proxy = "";
        client.connectTimeout = 1.seconds;
        client.operationTimeout = 2.seconds;
        client.addRequestHeader("x-autonom-client", token);
        client.setPostData(`{"text":"concurrent-event","ping":["target"]}`, "application/json");
        client.perform();
        client.statusLine.code.should == 201;
    }
    request("/api/rooms", 201, `{"name":"general"}`);
    Thread first = new Thread(&fire);
    Thread second = new Thread(&fire);
    first.start();
    second.start();
    first.join();
    second.join();
    waitUntil(delegate bool() {
        request("/api/health");
        return promptTexts(fixture.root).length == 2;
    });
    promptTexts(fixture.root).count!(text => text.length != 0).should == 2;
    request(sessionPath)["status"].str.should == "online";
    request(sessionPath)["activity"].str.should == "idle";
    request("/api/events?profile=target")["events"].array.length.should == 0;

    string due = (Clock.currTime(UTC()) + 2.seconds).toISOExtString();
    request("/api/schedules?profile=target", 201, JSONValue([
        "type": JSONValue("clock"), "at": JSONValue(due)
    ]).toString());
    // No HTTP request drives refresh here: the scheduler thread must poke its worker.
    waitUntil(delegate bool() {
        return promptTexts(fixture.root).length == 3;
    });

    long pending = peer.send("session/prompt", JSONValue([
        "sessionId": JSONValue(id),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("permission")])])
    ]));
    waitUntil(delegate bool() {
        return request(sessionPath)["activity"].str == "waiting";
    });
    request("/api/rooms/general/messages", 201, `{"text":"after-wait","ping":["target"]}`);
    promptTexts(fixture.root).length.should == 4;
    JSONValue offered = request(sessionPath~"/permissions");
    offered.array.length.should == 1;
    request(sessionPath~"/permissions", 200, JSONValue([
        "id": offered[0]["id"], "optionId": JSONValue("approve")
    ]).toString());
    peer.await(pending, 2.seconds)["stopReason"].str.should == "end_turn";
    waitUntil(delegate bool() {
        request("/api/health");
        return promptTexts(fixture.root).length == 5;
    });
    peer.close();
    waitUntil(delegate bool() {
        return request(sessionPath)["status"].str == "offline";
    });
}
