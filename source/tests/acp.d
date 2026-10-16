module tests.acp;

import daemon.interop.acp;
import daemon.interop.mcp : MCP_SERVER_NAME, injectCoord;
import daemon.relay.agent;
import tests.common;
import unit_threaded : Name, Serial, should, shouldThrow;

import core.sync.mutex : Mutex;
import core.sys.posix.unistd : read;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : canFind, endsWith;
import std.array : join, replicate, split;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process;
import std.socket;
import std.stdio : File;

private:

string agentPath()
    => buildPath(getcwd(), "source", "tests", "fakeagent.py");

string[] agentCommand()
    => ["python3", agentPath(), "acp"];

string[string] agentEnvironment(Fixture fixture)
    => [
        "AUTONOM_FAKE_DIR": fixture.root,
        "AUTONOM_FAKE_LOCKDIR": fixture.config.sessionLockDir,
        "PATH": environment.get("PATH", "/usr/bin:/bin")
    ];

class LineCollector
{
    Mutex mutex;
    string[] lines;
    string partial;
    bool done;

    this()
    {
        mutex = new Mutex;
    }

    void pump(File source)
    {
        try
        {
            ubyte[8192] buffer;
            for (;;)
            {
                immutable count = read(source.fileno, buffer.ptr, buffer.length);
                if (count <= 0)
                    break;

                synchronized (mutex)
                {
                    foreach (value; buffer[0..count])
                    {
                        if (value == '\n')
                        {
                            lines ~= partial.idup;
                            partial = null;
                        }
                        else if (value != '\r')
                            partial ~= cast(char)value;
                    }
                }
            }
        }
        catch (Exception)
        {
        }

        synchronized (mutex)
            done = true;
    }

    string[] snapshot()
    {
        synchronized (mutex)
            return lines.dup;
    }
}

public:

@Name("Relay forwards bytes in both directions without corruption")
unittest
{
    string large = `{"id":9,"data":"`~"x".replicate(2 * 1024 * 1024)~`"}`;
    string payload = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`~"\n"~
        "\n"~
        "this is not json\n"~
        `{"unicode":"héllo ⛄"}`~"\r\n"~
        large~"\n";

    File input = File.tmpfile();
    File output = File.tmpfile();
    scope(exit)
    {
        input.close();
        output.close();
    }

    input.write(payload);
    input.rewind();

    size_t observed;
    bool[] directions;
    int status = runRelay(
        ["/bin/cat"],
        null,
        null,
        (bool clientToAgent, string frame) {
            directions ~= clientToAgent;
            observed++;
        },
        null,
        input,
        output
    );
    status.should == 0;
    output.rewind();
    string echoed = cast(string)output.byChunk(4096).join;
    echoed.should == payload;
    observed.should == 8;
}

@Name("Relay propagates the child's exit status")
unittest
{
    File input = File.tmpfile();
    File output = File.tmpfile();
    scope(exit)
    {
        input.close();
        output.close();
    }

    runRelay(["/bin/false"], null, null, null, null, input, output).should == 1;
}

@Name("Relay rewrites session frames while forwarding other traffic unchanged")
unittest
{
    string sessionNew = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    string sessionLoad = `{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"s","pad":"`~
        "p".replicate(16 * 1024)~`"}}`;
    string prompt = `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s",`~
        `"text":"mentions \"session/load\" in prose"}}`;
    string notice = `{"jsonrpc":"2.0","method":"session/update","params":{"x":1}}`;
    string payload = sessionNew~"\n"~prompt~"\n"~sessionLoad~"\n"~notice~"\n";

    File input = File.tmpfile();
    File output = File.tmpfile();
    scope(exit)
    {
        input.close();
        output.close();
    }

    input.write(payload);
    input.rewind();

    int status = runRelay(
        ["/bin/cat"],
        null,
        null,
        null,
        null,
        input,
        output,
        (string frame) {
            JSONValue message = parseJSON(frame);
            if (message["method"].str != "session/new")
                return frame;

            message["params"]["injected"] = JSONValue(true);
            return message.toString();
        }
    );
    status.should == 0;
    output.rewind();
    string[] lines = (cast(string)output.byChunk(4096).join).split("\n");
    lines.length.should == 5;
    JSONValue first = parseJSON(lines[0]);
    first["params"]["injected"].boolean.should == true;
    first["params"]["cwd"].str.should == "/tmp";
    lines[1].should == prompt;
    lines[2].should == sessionLoad;
    lines[3].should == notice;
}

@Name("RelayAgent rewrites session creation and binds credentials on the response")
unittest
{
    RelayAgent agent = new RelayAgent("client-token", "18080", "connection", null);
    scope(exit)
        agent.close();

    string frame = `{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    JSONValue rewritten = parseJSON(agent.rewrite(frame));
    rewritten["id"].integer.should == 7;
    rewritten["method"].str.should == "session/new";
    JSONValue[] servers = rewritten["params"]["mcpServers"].array;
    servers.length.should == 1;
    servers[0]["name"].str.should == MCP_SERVER_NAME;
    string injected;
    foreach (entry; servers[0]["env"].array)
    {
        if (entry["name"].str == "AUTONOM_MCP_TOKEN")
            injected = entry["value"].str;
    }
    injected.length.should == 64;

    agent.rewrite(`{"jsonrpc":"2.0","method":"session/update","params":{}}`).should ==
        `{"jsonrpc":"2.0","method":"session/update","params":{}}`;
    agent.rewrite("not json").should == "not json";

    agent.frame(true, rewritten.toString());
    agent.frame(false, `{"jsonrpc":"2.0","id":7,"result":{"sessionId":"sess-1"}}`);
}

@Name("injectCoord replaces a stale entry and preserves other servers")
unittest
{
    JSONValue params = parseJSON(`{"cwd":"/x","mcpServers":[{"name":"other","command":"x"},`~
        `{"name":"autonom-coord","command":"stale","env":[]}]}`);
    JSONValue injected = injectCoord(params, "18080", "token-value");
    JSONValue[] servers = injected["mcpServers"].array;
    servers.length.should == 2;
    servers[0]["name"].str.should == "other";
    servers[1]["name"].str.should == MCP_SERVER_NAME;
    string[string] env;
    foreach (entry; servers[1]["env"].array)
        env[entry["name"].str] = entry["value"].str;
    env["AUTONOM_PORT"].should == "18080";
    env["AUTONOM_MCP_TOKEN"].should == "token-value";
    env["AUTONOM_RUN_TOKEN"].should == "";
    env["AUTONOM_CLIENT_TOKEN"].should == "";
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
    agent.agentRequest = (JSONValue message) {
        if (message["method"].str == "session/request_permission")
            return JSONValue(["outcome": JSONValue([
                "outcome": JSONValue("selected"),
                "optionId": JSONValue("reject_once")
            ])]);

        throw new AcpException(-32601, "Method not found");
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
    waitUntil(delegate bool()
    {
        return agent.poll(prompt, result, code, error);
    });
    result["stopReason"].str.should == "end_turn";
    waitUntil(delegate bool()
    {
        return agent.poll(steered, result, code, error);
    });
    result["stopReason"].str.should == "end_turn";

    agent.notify("session/cancel", JSONValue(["sessionId": JSONValue(session)]));
    waitUntil(delegate bool()
    {
        return agent.poll(hanging, result, code, error);
    });
    result["stopReason"].str.should == "cancelled";
    chunks.canFind("hello agent").should == true;
    chunks.canFind("steer me").should == true;
    agent.close();
}

@Name("AcpClient relays permission requests and unknown method errors")
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
        chunks ~= message["params"]["update"]["content"]["text"].str;
    };
    agent.agentRequest = (JSONValue message) {
        if (message["method"].str == "session/request_permission")
            return JSONValue(["outcome": JSONValue([
                "outcome": JSONValue("selected"),
                "optionId": JSONValue("reject_once")
            ])]);

        throw new AcpException(-32601, "Method not found");
    };

    agent.request("initialize", JSONValue(["protocolVersion": JSONValue(1)]), 10.seconds);
    JSONValue created = agent.request("session/new", JSONValue([
        "cwd": JSONValue(fixture.root),
        "mcpServers": JSONValue.emptyArray
    ]), 10.seconds);
    string session = created["sessionId"].str;

    agent.request("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("permission")])])
    ]), 10.seconds);
    chunks.canFind("PERM:reject_once").should == true;

    agent.request("session/prompt", JSONValue([
        "sessionId": JSONValue(session),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("probe-unknown")])])
    ]), 10.seconds);
    chunks.canFind("CODE:-32601").should == true;
    agent.close();
}

@Name("Relay control socket authenticates and injects prompts") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    string token = fixture.bridge.access.clientToken;
    write(buildPath(fixture.root, "next-session-id"), "ext-1");

    ProcessPipes relay = pipeProcess(
        ["bin/autonom-acp", "--devin", fixture.config.devinCommand, "--config", fixture.path],
        Redirect.stdin | Redirect.stdout,
        ["AUTONOM_PORT": "18080"]
    );
    scope(exit)
    {
        if (!tryWait(relay.pid).terminated)
        {
            relay.stdin.close();
            wait(relay.pid);
        }
    }

    LineCollector frames = new LineCollector();
    Thread reader = new Thread({
        frames.pump(relay.stdout);
    });
    reader.start();

    relay.stdin.write(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}`~"\n");
    relay.stdin.write(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"`~fixture.root~`","mcpServers":[]}}`~"\n");
    relay.stdin.flush();
    waitUntil(delegate bool()
    {
        foreach (line; frames.snapshot())
        {
            if (line.canFind("ext-1"))
                return true;
        }

        return false;
    });

    string socketPath;
    waitUntil(delegate bool()
    {
        string directory = buildPath(fixture.config.dataDir, "acp");
        if (!exists(directory))
            return false;

        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (entry.name.endsWith(".sock"))
                socketPath = entry.name;
        }

        return socketPath.length > 0;
    });

    string controlRoundTrip(JSONValue request)
    {
        Socket socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        scope(exit)
            socket.close();

        socket.connect(new UnixAddress(socketPath));
        socket.send(cast(ubyte[])(request.toString()~"\n"));
        string reply;
        ubyte[8192] buffer;
        for (;;)
        {
            immutable count = socket.receive(buffer);
            if (count <= 0)
                break;

            reply ~= cast(char[])buffer[0..count];
            if (reply.canFind("\n"))
                break;
        }

        return reply;
    }

    JSONValue rejected = parseJSON(controlRoundTrip(JSONValue([
        "token": JSONValue("wrong-token"),
        "id": JSONValue("control-1"),
        "method": JSONValue("session/prompt"),
        "params": JSONValue([
            "sessionId": JSONValue("ext-1"),
            "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("wrong")])])
        ])
    ])));
    rejected["error"]["code"].integer.should == -32001;

    JSONValue invalid = parseJSON(controlRoundTrip(JSONValue([
        "token": JSONValue(token),
        "id": JSONValue("control-2"),
        "method": JSONValue("session/prompt"),
        "params": JSONValue([
            "sessionId": JSONValue("unknown-session"),
            "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("unknown")])])
        ])
    ])));
    invalid["error"]["code"].integer.should == -32002;

    JSONValue prompted = parseJSON(controlRoundTrip(JSONValue([
        "token": JSONValue(token),
        "id": JSONValue("control-3"),
        "method": JSONValue("session/prompt"),
        "params": JSONValue([
            "sessionId": JSONValue("ext-1"),
            "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue("control prompt")])])
        ])
    ])));
    prompted["id"].str.should == "control-3";
    prompted["result"]["stopReason"].str.should == "end_turn";

    JSONValue cancelled = parseJSON(controlRoundTrip(JSONValue([
        "token": JSONValue(token),
        "id": JSONValue("control-4"),
        "method": JSONValue("session/cancel"),
        "params": JSONValue(["sessionId": JSONValue("ext-1")])
    ])));
    ("error" !in cancelled.object || cancelled["error"].isNull).should == true;

    Thread.sleep(100.msecs);
    foreach (line; frames.snapshot())
        line.canFind("control-3").should == false;

    relay.stdin.close();
    wait(relay.pid).should == 0;
    reader.join();
}
