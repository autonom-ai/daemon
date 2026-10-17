module tests.policy.context;

import daemon.policy.access : Policy;
import tests.common : Fixture;
import tests.policy.common : FakeRouter, installPolicy, policyFor;

import unit_threaded : Name, should, shouldThrow;

import std.json : JSONValue, parseJSON;

@Name("Policy sends screening input unchanged without mutating it")
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
    JSONValue input = parseJSON(`{
        "command":"OPENROUTER_API_KEY=secret-value curl -H 'Authorization: Bearer abc.def' `~
            `--token 'private token' sk-abcdefghijklmnopqrstuvwxyz 123e4567-e89b-12d3-a456-426614174000",
        "file_path":"/tmp/note.md",
        "content":"private content",
        "session_id":"private-session-id",
        "prompt_id":"private-prompt-id",
        "authorization":"private auth",
        "API_KEY":"private key",
        "nested":[{"text":"private text","token":"private token","path":"/tmp/other.md"}]
    }`);
    string original = input.toString();
    policy.check(fixture.root, "exec", input).denied.should == false;
    input.toString().should == original;
    router.payload["state"]["input"].should == input;
}

@Name("Policy passes all tool input fields to screening")
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
    policy.check(fixture.root, "post_message", parseJSON(`{
        "text":"message text","patch":"private patch","nested":{"text":"inner","token":"private token"}
    }`));
    router.payload["model"].str.should == "inception/mercury-decide:free";
    router.payload["state"]["input"]["text"].str.should == "message text";
    router.payload["state"]["input"]["patch"].str.should == "private patch";
    router.payload["state"]["input"]["nested"]["text"].str.should == "inner";
    router.payload["state"]["input"]["nested"]["token"].str.should == "private token";
}

@Name("Policy clears shared router context after successful failed and local requests")
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
    router.context.user("previous session");
    policy.check(fixture.root, "exec").denied.should == false;
    router.context.length.should == 0;
    router.failed = true;
    policy.check(fixture.root, "exec").shouldThrow!Exception();
    router.context.length.should == 0;
    router.failed = false;
    policy.check(fixture.root, "exec").denied.should == false;
    router.histories.should == [0, 0, 0];
    installPolicy(fixture, "rules:\n  - action: allow\n");
    router.context.user("previous session");
    policy.check(fixture.root, "exec").denied.should == false;
    router.context.length.should == 0;
}
