module tests.policy.common;

import daemon.policy.access : Policy;
import tests.common : Fixture, request;

import intuit.router.openrouter : OpenRouter;
import serverino : endpoint;

import core.time : Duration;
import std.file : mkdirRecurse, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;

class FakeRouter : OpenRouter
{
    size_t calls;
    size_t catalogs;
    size_t[] histories;
    Duration timeout;
    Duration connectionTimeout;
    JSONValue payload;
    string reply = `{"answers":{"inspect":{"type":"noul","noul":0}}}`;
    string unavailableModel;
    string[] attemptedModels;
    bool failed;

    this()
    {
        super("test-key");
    }

    override void refresh()
    {
        catalogs++;
    }

    override void operationTimeout(Duration timeout)
    {
        this.timeout = timeout;
    }

    override void connectTimeout(Duration timeout)
    {
        connectionTimeout = timeout;
    }

    override JSONValue _decisions(JSONValue payload)
    {
        calls++;
        histories ~= context.length;
        attemptedModels ~= active;
        this.payload = payload;
        context.user("request state");
        context.assistant("decision");
        if (failed || active == unavailableModel)
            throw new Exception("Mock policy endpoint failed");

        return parseJSON(reply);
    }
}

void installPolicy(Fixture fixture, string content)
{
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    write(buildPath(fixture.root, ".devin", "policy.yml"), content);
}

Policy policyFor(Fixture fixture, FakeRouter router)
{
    fixture.config.router = router;
    return new Policy(fixture.config);
}
