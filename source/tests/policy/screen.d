module tests.policy.screen;

import daemon.policy.access : Policy;
import tests.common : Fixture, request;
import tests.policy.common : FakeRouter, installPolicy, policyFor;

import unit_threaded : Name, should, shouldThrow;

import core.time : Duration, seconds;
import std.file : readText;
import std.json : JSONValue, parseJSON;

@Name("Policy screens with typed predicate questions and a configurable threshold")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, `rules:
  - action: screen
    models: [test-model]
    questions:
      - type: predicate
        name: destructive
        instructions: '  Would this destroy files?  '
      - type: predicate
        name: exfiltration
        instructions: Would this send private data outside?
    threshold: 0.75
    reason: Destructive command
`);
    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    JSONValue input = parseJSON(`{"command":"git status"}`);
    router.reply = `{"answers":{"destructive":{"type":"noul","noul":0.74},`~
        `"exfiltration":{"type":"noul","noul":0.2}}}`;
    policy.check(fixture.root, "exec", input).denied.should == false;
    router.payload["model"].str.should == "test-model";
    router.payload["state"]["tool"].str.should == "exec";
    router.payload["state"]["input"].should == input;
    router.payload["questions"]["destructive"]["type"].str.should == "noul";
    router.payload["questions"]["destructive"]["instructions"].str.should == "Would this destroy files?";
    router.payload["questions"]["exfiltration"]["instructions"].str.should ==
        "Would this send private data outside?";
    router.reply = `{"answers":{"destructive":{"type":"noul","noul":0.2},`~
        `"exfiltration":{"type":"noul","noul":0.75}}}`;
    policy.check(fixture.root, "exec", input).denied.should == true;
    policy.check(fixture.root, "exec", input).reason.should == "Destructive command";
    router.calls.should == 3;
    router.catalogs.should == 1;
    (router.timeout > Duration.zero && router.timeout <= 8.seconds).should == true;
    router.connectionTimeout.should == 2.seconds;
}

@Name("Policy falls back through screening models in file order")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, `rules:
  - action: screen
    models: [unavailable-model, fallback-model]
    questions:
      - type: predicate
        name: inspect
        instructions: Is the request allowed?
`);
    FakeRouter router = new FakeRouter();
    router.unavailableModel = "unavailable-model";
    Policy policy = policyFor(fixture, router);
    policy.check(fixture.root, "exec").denied.should == false;
    router.attemptedModels.should == ["unavailable-model", "fallback-model"];
    router.payload["model"].str.should == "fallback-model";
    router.context.length.should == 0;
}

@Name("Policy ships a default template that screens with its configured model")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, readText("templates/policy.yml"));
    FakeRouter router = new FakeRouter();
    router.reply = `{"answers":{"safety":{"type":"noul","noul":0}}}`;
    Policy policy = policyFor(fixture, router);
    policy.check(fixture.root, "exec", parseJSON(`{"command":"git status"}`)).denied.should == false;
    router.payload["model"].str.should == "inception/mercury-decide:free";
    router.payload["questions"]["safety"]["type"].str.should == "noul";
    router.context.length.should == 0;
}

@Name("Policy rejects missing malformed and refused model decisions")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture,
        "rules:\n  - action: screen\n    models: [\"inception/mercury-decide:free\"]\n"~
            "    questions: [{type: predicate, name: inspect, instructions: 'Inspect?'}]\n");
    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    foreach (reply; [
        `{}`,
        `{"answers":{}}`,
        `{"answers":{"other":{"type":"noul","noul":0}}}`,
        `{"answers":{"inspect":{"type":"noul","noul":-0.1}}}`,
        `{"answers":{"inspect":{"type":"noul","noul":1.1}}}`,
        `{"answers":{"inspect":{"type":"noul","noul":"NaN"}}}`,
        `{"answers":{"inspect":{"type":"noul","noul":null}}}`,
        `{"answers":{"inspect":{"type":"noul"}}}`,
        `{"answers":{"inspect":{"type":"choice","choice":"allow"}}}`,
        `{"answers":{"inspect":{"type":"refusal"}}}`,
        `{"error":{"message":"failed"}}`
    ])
    {
        router.reply = reply;
        policy.check(fixture.root, "exec").shouldThrow!Exception();
        router.context.length.should == 0;
    }
}
