/// Exercises the installed CLI with isolated XDG state and no model credentials.
module tests.integration.devin;

version(devin)
{
    import daemon.config : Config;
    import daemon.interop.acp : AcpClient, AcpException, Frame, frameLimit;
    import daemon.interop.devin.options : promptParams, sessionParams;
    import daemon.interop.devin.bridge : Bridge;
    import daemon.interop.devin.db : readSessionMetadata;
    import daemon.interop.metadata : SessionMetadata;
    import daemon.interop.process : createProcessGroup, terminate;
    import tests.common : waitUntil;
    import tests.interop.acp.common : LineCollector;

    import unit_threaded;

    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import core.time : seconds;
    import std.array : replicate;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath;
    import std.process : ProcessConfig = Config, environment, pipeProcess, Pid, ProcessPipes, Redirect, tryWait;
    import std.stdio : File;
    import std.uuid : randomUUID;

    @Name("Devin accepts the frame boundary and reloads large history through the production connector") @Serial
    unittest
    {
        string root = buildPath(tempDir(), "autonom-devin-"~randomUUID().toString());
        mkdirRecurse(root);
        scope(exit)
            rmdirRecurse(root);

        string data = buildPath(root, "data");
        string database = buildPath(data, "devin", "cli", "sessions.db");
        string command = environment.get("AUTONOM_TEST_DEVIN", "devin");
        string[string] child = [
            "PATH": environment.get("PATH", "/usr/bin:/bin"),
            "XDG_CONFIG_HOME": buildPath(root, "config"),
            "XDG_DATA_HOME": data,
            "XDG_CACHE_HOME": buildPath(root, "cache")
        ];
        File errors = File.tmpfile();
        scope(exit)
            errors.close();
        string[] connector = [buildPath("bin", "autonom-acp"), "--devin", command];
        // The connector runs from the repository while its real CLI uses isolated XDG state.
        AcpClient agent = new AcpClient(connector, child, null, errors);
        scope(exit)
            agent.close();

        JSONValue initialize = JSONValue([
            "protocolVersion": JSONValue(1),
            "clientCapabilities": JSONValue.emptyObject,
            "clientInfo": JSONValue(["name": JSONValue("autonom"), "version": JSONValue("1")]),
            "_meta": JSONValue(["padding": JSONValue("")])
        ]);
        Frame boundary = Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": JSONValue(1),
            "method": JSONValue("initialize"),
            "params": initialize
        ]));
        initialize["_meta"]["padding"] = JSONValue("x".replicate(frameLimit + 1 - boundary.encode().length));
        boundary.encode().length.should == frameLimit + 1; // Includes the newline delimiter.
        agent.request("initialize", initialize, 30.seconds)["protocolVersion"].integer.should == 1;

        initialize["_meta"]["padding"] = JSONValue(initialize["_meta"]["padding"].str~"x");
        agent.request("initialize", initialize, 30.seconds).shouldThrow!Exception;
        JSONValue created = agent.request("session/new", sessionParams(root), 30.seconds);
        string id = created["sessionId"].str;

        string prompt = "Large persisted ACP input.\n"~"history-boundary-0123456789\n".replicate(40_000);
        bool unauthenticated;
        try
            agent.request("session/prompt", promptParams(id, prompt), 15.seconds);
        catch (AcpException error)
        {
            error.code.should == -32000;
            unauthenticated = true;
        }
        unauthenticated.should == true;
        agent.close();

        SessionMetadata metadata = readSessionMetadata(database, id);
        metadata.id.should == id;
        metadata.acp.should == "autonom";
        metadata.directory.should == root;

        AcpClient loaded = new AcpClient(connector, child, null, errors);
        scope(exit)
            loaded.close();

        loaded.request("initialize", JSONValue([
            "protocolVersion": JSONValue(1),
            "clientCapabilities": JSONValue.emptyObject
        ]), 30.seconds);
        Mutex notifications = new Mutex();
        string replayed;
        size_t largest;
        loaded.notification = (JSONValue frame) {
            if (frame["method"].str != "session/update")
                return;

            JSONValue update = frame["params"]["update"];
            if (update["sessionUpdate"].str != "user_message_chunk" ||
                update["content"]["type"].str != "text")
                return;

            synchronized (notifications)
            {
                replayed ~= update["content"]["text"].str;
                size_t bytes = frame.toString().length;
                if (bytes > largest)
                    largest = bytes;
            }
        };
        loaded.request("session/load", sessionParams(root, id), 30.seconds);
        synchronized (notifications)
        {
            replayed.should == prompt;
            (largest > 1024 * 1024 && largest <= frameLimit).should == true;
        }
        loaded.close();

        string config = buildPath(root, "autonom.yml");
        write(config, "devinCommand: "~JSONValue(command).toString()~"\n"~
            "dataDir: autonom\nsessionLockDir: "~JSONValue(buildPath(data, "devin", "cli", "session_locks")).toString()~"\n"~
            "router:\n  type: openrouter\n  key: unused\n  url: https://openrouter.ai\n  name: OpenRouter\n");
        Bridge first = new Bridge(new Config(config));
        first.list(null, "autonom")[0].id.should == id;
        first.close();
        Bridge restarted = new Bridge(new Config(config));
        scope(exit)
            restarted.close();
        restarted.list(null, "autonom")[0].id.should == id;
        restarted.access.managed(id).should == false;
        exists(database).should == true;
    }

    @Name("Installed CLI forwarding handles fragmented and coalesced requests and rejects malformed input") @Serial
    unittest
    {
        string root = buildPath(tempDir(), "autonom-devin-"~randomUUID().toString());
        mkdirRecurse(root);
        scope(exit)
            rmdirRecurse(root);

        string[string] child = [
            "PATH": environment.get("PATH", "/usr/bin:/bin"),
            "XDG_CONFIG_HOME": buildPath(root, "config"),
            "XDG_DATA_HOME": buildPath(root, "data"),
            "XDG_CACHE_HOME": buildPath(root, "cache")
        ];
        ProcessConfig options = ProcessConfig.newEnv;
        options.preExecFunction = &createProcessGroup;
        ProcessPipes relay = pipeProcess([
            buildPath("bin", "autonom-acp"),
            "--devin",
            environment.get("AUTONOM_TEST_DEVIN", "devin")
        ], Redirect.stdin | Redirect.stdout, child, options);
        LineCollector frames = new LineCollector();
        Thread reader = new Thread({ frames.pump(relay.stdout); });
        reader.start();
        scope(exit)
        {
            relay.stdin.close();
            terminate(relay.pid, 1.seconds);
            reader.join();
        }

        JSONValue find(JSONValue id)
        {
            foreach (line; frames.snapshot())
            {
                JSONValue frame = parseJSON(line);
                if ("id" in frame.object && frame["id"] == id)
                    return frame;
            }

            return JSONValue(null);
        }

        string initialize = `{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}`;
        relay.stdin.write(initialize[0..35]);
        relay.stdin.flush();
        relay.stdin.writeln(initialize[35..$]);
        relay.stdin.flush();
        waitUntil(delegate bool() {
            return !find(JSONValue("initialize")).isNull;
        }, 30.seconds);
        find(JSONValue("initialize"))["result"]["protocolVersion"].integer.should == 1;

        relay.stdin.write(
            `{"jsonrpc":"2.0","id":"1","method":"session/list","params":{}}`~"\n"~
            `{"jsonrpc":"2.0","id":1,"method":"session/list","params":{}}`~"\n");
        relay.stdin.flush();
        waitUntil(delegate bool() {
            return !find(JSONValue("1")).isNull && !find(JSONValue(1)).isNull;
        }, 30.seconds);
        find(JSONValue("1"))["result"]["sessions"].array.length.should == 0;
        find(JSONValue(1))["result"]["sessions"].array.length.should == 0;

        relay.stdin.writeln(`{"jsonrpc":"2.0","id":"bad","method":"session/list","result":{}}`);
        relay.stdin.flush();
        typeof(tryWait(Pid.init)) result;
        waitUntil(delegate bool() {
            result = tryWait(relay.pid);
            return result.terminated;
        }, 10.seconds);
        result.status.should == 1;
        find(JSONValue("bad")).isNull.should == true;
    }
}
