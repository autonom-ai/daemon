module tests.integration.partition;

version(devin)
{
    import daemon.interop.acp : AcpClient, AcpException;
    import daemon.interop.devin.options : promptParams, sessionParams;
    import daemon.interop.devin.db : readSessionMetadata;

    import unit_threaded : Name, Serial, should;

    import core.time : seconds;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.json : JSONValue;
    import std.path : buildPath;
    import std.process : environment;
    import std.stdio : File;
    import std.uuid : randomUUID;

    @Name("Installed CLI partitions session catalogs and locks without redirecting credentials") @Serial
    unittest
    {
        string root = buildPath(tempDir(), "autonom-partition-"~randomUUID().toString());
        mkdirRecurse(root);
        scope(exit)
            rmdirRecurse(root);

        string native = buildPath(root, "data", "devin", "cli", "sessions.db");
        string managed = buildPath(root, "autonom", "cli", "sessions.db");
        string[string] child = [
            "PATH": environment.get("PATH", "/usr/bin:/bin"),
            "XDG_CONFIG_HOME": buildPath(root, "config"),
            "XDG_DATA_HOME": buildPath(root, "data"),
            "XDG_CACHE_HOME": buildPath(root, "cache")
        ];
        string command = environment.get("AUTONOM_TEST_DEVIN", "devin");
        File errors = File.tmpfile();
        scope(exit)
            errors.close();

        string create(string database)
        {
            string[string] settings = child.dup;
            if (database.length)
                settings["CHISEL_SESSION_DB"] = database;

            AcpClient agent = new AcpClient([command, "acp"], settings, root, errors);
            scope(exit)
                agent.close();

            agent.request("initialize", JSONValue([
                "protocolVersion": JSONValue(1),
                "clientCapabilities": JSONValue.emptyObject
            ]), 30.seconds);
            agent.request("session/list")["sessions"].array.length.should == 0;
            string id = agent.request("session/new", sessionParams(root))["sessionId"].str;
            try
                agent.request("session/prompt", promptParams(id, "Persist without model credentials"), 15.seconds);
            catch (AcpException error)
                error.code.should == -32000;

            JSONValue sessions = agent.request("session/list")["sessions"];
            sessions.array.length.should == 1;
            sessions[0]["sessionId"].str.should == id;
            return id;
        }

        string nativeId = create(null);
        string managedId = create(managed);
        readSessionMetadata(native, nativeId).id.should == nativeId;
        readSessionMetadata(native, managedId).id.length.should == 0;
        readSessionMetadata(managed, managedId).id.should == managedId;
        readSessionMetadata(managed, nativeId).id.length.should == 0;
    }
}
