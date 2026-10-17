module tests.policy.rule;

import daemon.policy.access : Policy, checkPolicy;
import tests.common : Fixture, request;
import tests.policy.common : FakeRouter, installPolicy, policyFor;

import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import std.array : replicate;
import std.file : remove, symlink;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.traits : hasUDA;

@Name("Policy declares its module-level HTTP endpoint")
unittest
{
    hasUDA!(checkPolicy, endpoint).should == true;
    hasUDA!(checkPolicy, route).should == true;
}

@Name("Policy uses the first matching rule without calling the router for local decisions")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, `rules:
  - action: deny
    match:
      tool: '^exec$'
      command: 'rm\s+-rf'
    reason: Destructive command
  - action: allow
    match: {tool: '^exec$'}
  - action: deny
`);
    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    policy.check(fixture.root, "exec", parseJSON(`{"command":"rm -rf /"}`)).denied.should == true;
    policy.check(fixture.root, "exec", parseJSON(`{"command":"rm -rf /"}`)).reason.should ==
        "Destructive command";
    policy.check(fixture.root, "exec", parseJSON(`{"command":"git status"}`)).denied.should == false;
    policy.check(fixture.root, "read").denied.should == true;
    policy.check(fixture.root, "exec", parseJSON(`{"command":42}`)).denied.should == false;
    router.calls.should == 0;
    router.catalogs.should == 0;
    router.context.length.should == 0;
}

@Name("Policy denies unmatched requests and reloads workspace changes")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, "rules: []\n");
    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    policy.check(fixture.root, "exec").denied.should == true;
    policy.check(fixture.root, "exec").reason.should == "No policy rule matched";
    installPolicy(fixture, "rules:\n  - action: allow\n");
    policy.check(fixture.root, "exec").denied.should == false;
    installPolicy(fixture, "rules:\n  - action: deny\n");
    policy.check(fixture.root, "exec").denied.should == true;
    router.calls.should == 0;
}

@Name("Policy rejects invalid documents before applying any rule")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    foreach (content; [
        "",
        "[]",
        "{}",
        "rules: [",
        "rules: {}",
        "rules: [42]",
        "rules:\n  - reason: missing action\n",
        "rules:\n  - action: unknown\n",
        "rules:\n  - action: screen\n",
        "rules:\n  - action: screen\n    questions: {}\n",
        "rules:\n  - action: screen\n    questions: invalid\n",
        "rules:\n  - action: screen\n    questions: [{type: predicate, name: inspect, instructions: ' '}]\n",
        "rules:\n  - action: screen\n    questions: [42]\n",
        "rules:\n  - action: screen\n    questions: [{type: choice, name: inspect, instructions: 'Pick one'}]\n",
        "rules:\n  - action: deny\n    match: {tool: '['}\n",
        "rules:\n  - action: deny\n    match: []\n",
        "rules:\n  - action: deny\n    match: {tool: 42}\n",
        "rules:\n  - action: allow\n  - action: screen\n",
        "rules:\n  - action: allow\n    unexpected: true\n",
        "rules:\n  - action: screen\n    questions:\n      - {type: predicate, name: inspect, "~
            "instructions: 'Allowed?'}\n    threshold: -0.1\n",
        "rules:\n  - action: screen\n    questions:\n      - {type: predicate, name: inspect, "~
            "instructions: 'Allowed?'}\n    threshold: 1.1\n",
        "rules:\n  - action: screen\n    questions:\n      - {type: predicate, name: inspect, "~
            "instructions: 'Allowed?'}\n    threshold: .nan\n",
        "rules:\n  - action: screen\n    models: []\n    questions: "~
            "[{type: predicate, name: inspect, instructions: 'Allowed?'}]\n",
        "rules:\n  - action: screen\n    questions: "~
            "[{type: predicate, name: inspect, instructions: 'Allowed?'}]\n",
        "rules:\n  - action: screen\n    models: [test-model, test-model]\n    questions: "~
            "[{type: predicate, name: inspect, instructions: 'Allowed?'}]\n",
        "rules:\n  - action: screen\n    questions:\n      - {type: predicate, name: inspect, "~
            "instructions: 'Allowed?'}\n    expose: [text]\n",
        "rules:\n  - action: screen\n    question: 'Legacy question field'\n",
        "rules: []\npermissions: []\n"
    ])
    {
        installPolicy(fixture, content);
        policy.check(fixture.root, "exec").shouldThrow!Exception();
    }

    router.calls.should == 0;
}

@Name("Policy requires a regular bounded workspace file and valid request")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    FakeRouter router = new FakeRouter();
    Policy policy = policyFor(fixture, router);
    policy.check(fixture.root, "exec").shouldThrow!Exception();
    installPolicy(fixture, "rules:\n  - action: allow\n");
    policy.check("", "exec").shouldThrow!Exception();
    policy.check(fixture.root, "").shouldThrow!Exception();
    policy.check(fixture.root, "exec", JSONValue(null)).shouldThrow!Exception();
    installPolicy(fixture, "rules: []\n"~" ".replicate(64 * 1024));
    policy.check(fixture.root, "exec").shouldThrow!Exception();
    string path = buildPath(fixture.root, ".devin", "policy.yml");
    remove(path);
    symlink(fixture.path, path);
    policy.check(fixture.root, "exec").shouldThrow!Exception();
    router.calls.should == 0;
    router.context.length.should == 0;
}
