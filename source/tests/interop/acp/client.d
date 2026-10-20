module tests.interop.acp.client;

import daemon.interop.acp;
import daemon.interop.devin.options : promptParams;
import daemon.interop.session : TurnStatus;
import tests.common;
import tests.interop.acp.common;

import unit_threaded;

import core.time : msecs, seconds;
import std.algorithm : canFind;
import std.json : JSONValue;
import std.stdio : File;

@Name("Automatic prompt admission refuses a newly pending human request without sending it")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    AcpClient agent = new AcpClient(agentCommand(), agentEnvironment(fixture), fixture.root);
    scope(exit)
        agent.close();
    agent.request("initialize", JSONValue([
        "protocolVersion": JSONValue(1), "clientCapabilities": JSONValue.emptyObject
    ]), 1.seconds);
    string session = agent.request("session/new", JSONValue([
        "cwd": JSONValue(fixture.root), "mcpServers": JSONValue.emptyArray
    ]), 1.seconds)["sessionId"].str;
    long request = agent.send("session/prompt", promptParams(session, "permission"));
    waitUntil(delegate bool() {
        return agent.activity(session) == TurnStatus.Waiting;
    });
    bool refused;
    try
        agent.deliver(promptParams(session, "must-not-interrupt"));
    catch (AcpException error)
    {
        error.code.should == -32015;
        refused = true;
    }
    refused.should == true;
    JSONValue pending = agent.permissions(session);
    pending.array.length.should == 1;
    agent.decide(session, pending[0]["id"].integer, "approve");
    agent.await(request, 1.seconds)["stopReason"].str.should == "end_turn";
    agent.activity(session).should == TurnStatus.Idle;
    agent.await(agent.deliver(promptParams(session, "after-wait")), 1.seconds)["stopReason"].str.should == "end_turn";
}

@Name("AcpClient performs initialize, session, prompt, and cancellation")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    File errors = File.tmpfile();
    scope(exit)
        errors.close();

    AcpClient agent = new AcpClient(agentCommand(), agentEnvironment(fixture), fixture.root, errors);
    scope(exit)
        agent.close();

    string chunks;
    agent.notification = (JSONValue message) {
        JSONValue update = message["params"]["update"];
        if (update["sessionUpdate"].str == "agent_message_chunk")
            chunks ~= update["content"]["text"].str;
    };
    JSONValue initialized = agent.request("initialize", JSONValue([
        "protocolVersion": JSONValue(1),
        "clientCapabilities": JSONValue.emptyObject
    ]), 10.seconds);
    initialized["protocolVersion"].integer.should == 1;

    JSONValue created = agent.request("session/new", JSONValue([
        "cwd": JSONValue(fixture.root),
        "mcpServers": JSONValue.emptyArray
    ]), 10.seconds);
    string session = created["sessionId"].str;
    (session.length != 0).should == true;

    long prompt = agent.send("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("hello agent")])])
    ]));
    long steered = agent.send("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("steer me")])])
    ]));
    long hanging = agent.send("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("hang")])])
    ]));

    JSONValue result;
    int code;
    string error;
    waitUntil(delegate bool() {
        return agent.poll(prompt, result, code, error);
    });
    result["stopReason"].str.should == "end_turn";
    waitUntil(delegate bool() {
        return agent.poll(steered, result, code, error);
    });
    result["stopReason"].str.should == "end_turn";

    agent.notify("session/cancel", JSONValue(["sessionId": JSONValue(session)]));
    waitUntil(delegate bool() {
        return agent.poll(hanging, result, code, error);
    });
    result["stopReason"].str.should == "cancelled";
    chunks.canFind("hello agent").should == true;
    chunks.canFind("steer me").should == true;

    long exiting = agent.send("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue([
            "type": JSONValue("text"),
            "text": JSONValue("exit-after-reply")
        ])])
    ]));
    waitUntil(delegate bool() {
        return agent.disconnected;
    });
    agent.await(exiting, 1.seconds)["stopReason"].str.should == "end_turn";
    agent.close();
}

@Name("ACP permissions clear on session cancellation, backend cancellation, and expiry")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    AcpClient agent = new AcpClient(agentCommand(), agentEnvironment(fixture), fixture.root);
    scope(exit)
        agent.close();

    agent.request("initialize", JSONValue([
        "protocolVersion": JSONValue(1),
        "clientCapabilities": JSONValue.emptyObject
    ]), 1.seconds);
    string session = agent.request("session/new", JSONValue([
        "cwd": JSONValue(fixture.root),
        "mcpServers": JSONValue.emptyArray
    ]), 1.seconds)["sessionId"].str;
    JSONValue params = JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue([
            "type": JSONValue("text"),
            "text": JSONValue("permission")
        ])])
    ]);
    long pending = agent.send("session/prompt", params);
    waitUntil(delegate bool() {
        return agent.permissions(session).array.length == 1;
    });
    agent.notify("session/cancel", JSONValue(["sessionId": JSONValue(session)]));
    agent.permissions(session).array.length.should == 0;
    agent.await(pending, 1.seconds)["stopReason"].str.should == "end_turn";

    params["prompt"][0]["text"] = JSONValue("cancel-permission");
    agent.request("session/prompt", params, 1.seconds)["stopReason"].str.should == "end_turn";
    agent.permissions(session).array.length.should == 0;

    agent.permissionTimeout = 10.msecs;
    params["prompt"][0]["text"] = JSONValue("permission");
    agent.request("session/prompt", params, 1.seconds)["stopReason"].str.should == "end_turn";
    agent.permissions(session).array.length.should == 0;
}
