module tests.http.permissions;

import tests.common;
import tests.http.common;

import unit_threaded;

import std.json : JSONValue;

@Name("HTTP permission decisions select only offered options and settle the ACP request once") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit) daemon.close();
    JSONValue accepted = request("/api/sessions", 202, JSONValue([
        "directory": JSONValue(fixture.root), "prompt": JSONValue("permission")
    ]).toString());
    JSONValue pending;
    string session;
    waitUntil(delegate bool()
    {
        JSONValue call = request("/api/executions/"~accepted["id"].str);
        if (call["sessionId"].isNull)
            return false;
        session = call["sessionId"].str;
        pending = request("/api/sessions/"~session~"/permissions");
        return pending.array.length != 0;
    });
    string path = "/api/sessions/"~session~"/permissions";
    JSONValue decision = JSONValue(["id": pending[0]["id"], "optionId": JSONValue("not-offered")]);
    request(path, 400, decision.toString());
    decision["optionId"] = pending[0]["options"][0]["optionId"];
    request(path, 200, decision.toString());
    request(path, 409, decision.toString());
    waitForCall(accepted)["status"].str.should == "succeeded";
    request(path).array.length.should == 0;
}

@Name("HTTP permission decisions settle via path-based requestId endpoint") @Serial
unittest
{
    import std.conv : to;

    Fixture fixture = Fixture.create();
    scope(exit) fixture.close();
    installFake(fixture);
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit) daemon.close();
    JSONValue accepted = request("/api/sessions", 202, JSONValue([
        "directory": JSONValue(fixture.root), "prompt": JSONValue("permission")
    ]).toString());
    JSONValue pending;
    string session;
    waitUntil(delegate bool()
    {
        JSONValue call = request("/api/executions/"~accepted["id"].str);
        if (call["sessionId"].isNull)
            return false;
        session = call["sessionId"].str;
        pending = request("/api/sessions/"~session~"/permissions");
        return pending.array.length != 0;
    });
    long reqId = pending[0]["id"].integer;
    string pathWithId = "/api/sessions/"~session~"/permissions/"~to!string(reqId);
    JSONValue pendingSpecific = request(pathWithId);
    pendingSpecific.array.length.should == 1;
    pendingSpecific[0]["id"].integer.should == reqId;

    JSONValue decision = JSONValue(["optionId": pending[0]["options"][0]["optionId"]]);
    request(pathWithId, 200, decision.toString());
    request(pathWithId, 409, decision.toString());
    waitForCall(accepted)["status"].str.should == "succeeded";
}
