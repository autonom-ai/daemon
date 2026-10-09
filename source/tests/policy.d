module tests.policy;

import autonom.policy : Policy;
import autonom.api.policy : checkPolicy;
import tests.common : Fixture;
import intuit.router.openrouter : OpenRouter;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import core.time : Duration, seconds;
import std.array : replicate;
import std.file : mkdirRecurse, remove, symlink, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.traits : hasUDA;

private:

class FakeRouter : OpenRouter
{
public:
    size_t calls;
    size_t catalogs;
    size_t[] histories;
    Duration timeout;
    Duration connectionTimeout;
    JSONValue payload;
    string reply = `{"answers":{"inspect":{"type":"noul","noul":0}}}`;
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
        this.payload = payload;
        context.user("request state");
        context.assistant("decision");
        if (failed)
            throw new Exception("Mock policy endpoint failed");

        return parseJSON(reply);
    }
}

void installPolicy(Fixture fixture, string content)
{
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    write(buildPath(fixture.root, ".devin", "policy.yml"), content);
}

public:

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
    Policy policy = new Policy(router, "test-model");
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
    Policy policy = new Policy(router, "test-model");
    policy.check(fixture.root, "exec").denied.should == true;
    policy.check(fixture.root, "exec").reason.should == "No policy rule matched";
    installPolicy(fixture, "rules:\n  - action: allow\n");
    policy.check(fixture.root, "exec").denied.should == false;
    installPolicy(fixture, "rules:\n  - action: deny\n");
    policy.check(fixture.root, "exec").denied.should == true;
    router.calls.should == 0;
}

@Name("Policy screens with typed predicate questions and a configurable threshold")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture, `rules:
  - action: screen
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
    Policy policy = new Policy(router, "test-model");
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

@Name("Policy sends screening input unchanged without mutating it")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture,
        "rules:\n  - action: screen\n    questions: [{type: predicate, name: inspect, instructions: 'Inspect?'}]\n");
    FakeRouter router = new FakeRouter();
    Policy policy = new Policy(router, "test-model");
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
        "rules:\n  - action: screen\n    questions: [{type: predicate, name: inspect, instructions: 'Inspect?'}]\n");
    FakeRouter router = new FakeRouter();
    Policy policy = new Policy(router, "test-model");
    policy.check(fixture.root, "post_message", parseJSON(`{
        "text":"message text","patch":"private patch","nested":{"text":"inner","token":"private token"}
    }`));
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
        "rules:\n  - action: screen\n    questions: [{type: predicate, name: inspect, instructions: 'Inspect?'}]\n");
    FakeRouter router = new FakeRouter();
    Policy policy = new Policy(router, "test-model");
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

@Name("Policy rejects missing malformed and refused model decisions")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installPolicy(fixture,
        "rules:\n  - action: screen\n    questions: [{type: predicate, name: inspect, instructions: 'Inspect?'}]\n");
    FakeRouter router = new FakeRouter();
    Policy policy = new Policy(router, "test-model");
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

@Name("Policy rejects invalid documents before applying any rule")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    FakeRouter router = new FakeRouter();
    Policy policy = new Policy(router, "test-model");
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
    Policy policy = new Policy(router, "test-model");
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
