/// Exercises the installed CLI with isolated XDG state and no model credentials.
module tests.integration.devin;

version(devin)
{
    import daemon.config : Config;
    import daemon.interop.acp : AcpClient, AcpException;
    import daemon.interop.bridge : Bridge;
    import daemon.interop.devin.acp : promptParams, sessionParams;
    import daemon.interop.devin.db : readSessionMetadata;
    import daemon.interop.metadata : SessionMetadata;

    import unit_threaded;

    import core.time : seconds;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : JSONValue;
    import std.path : buildPath;
    import std.process : environment;
    import std.stdio : File;
    import std.uuid : randomUUID;

    @Name("Devin persists the ACP connector marker and Bridge filters it after restart") @Serial
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
        AcpClient agent = new AcpClient([command, "acp"], child, root, errors);
        scope(exit)
            agent.close();

        agent.request("initialize", JSONValue([
            "protocolVersion": JSONValue(1),
            "clientCapabilities": JSONValue.emptyObject,
            "clientInfo": JSONValue(["name": JSONValue("autonom"), "version": JSONValue("1")])
        ]), 30.seconds);
        JSONValue created = agent.request("session/new", sessionParams(root), 30.seconds);
        string id = created["sessionId"].str;

        bool unauthenticated;
        try
            agent.request("session/prompt", promptParams(id, "Reply OK"), 15.seconds);
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
}
