module tests.common;

import daemon.agent;
import daemon.config;
import daemon.interop.bridge;

import std.algorithm.searching : startsWith;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath;
import std.uuid;

public:

enum ROUTER = "router:\n  type: openrouter\n  key: test-key\n  url: https://openrouter.ai\n  name: OpenRouter\n";
string requestToken;
string[string] hookTokens;

JSONValue request(
    string path,
    uint status = 200,
    string data = null,
    string contentType = "application/json",
    HTTP.Method method = HTTP.Method.undefined,
    string runToken = null,
    string session = null,
    bool control = true,
    string mcpToken = null
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 2.seconds;
    client.method = method;
    if (control && requestToken.length)
        client.addRequestHeader("x-autonom-client", requestToken);
    if (runToken.length)
        client.addRequestHeader("x-autonom-run", runToken);
    if (session.length)
        client.addRequestHeader("x-autonom-session", session);
    if (mcpToken.length)
        client.addRequestHeader("x-autonom-mcp", mcpToken);
    if (!runToken.length && control && path.startsWith("/api/hooks/") && data.length)
    {
        try
        {
            JSONValue payload = parseJSON(data);
            if ("session_id" in payload.object)
            {
                string* token = payload["session_id"].str in hookTokens;
                if (token !is null)
                    client.addRequestHeader("x-autonom-run", *token);
            }
        }
        catch (Exception)
        {
        }
    }

    if (data !is null)
        client.setPostData(data, contentType);

    string body;
    client.onReceive = (ubyte[] chunk)
    {
        body ~= cast(char[])chunk;
        return chunk.length;
    };
    client.perform();
    if (client.statusLine.code != status)
        throw new Exception("HTTP "~client.statusLine.code.to!string~" for "~path~": "~body);

    return parseJSON(body);
}

struct Fixture
{
public:
    string root;
    string path;
    Config config;
    Bridge bridge;
    ProfileStore store;

    static Fixture create(string command = "./devin")
    {
        Fixture ret;
        ret.root = buildPath(tempDir(), "autonom-"~randomUUID().toString());
        mkdirRecurse(ret.root);
        scope(failure)
            rmdirRecurse(ret.root);

        ret.path = buildPath(ret.root, "config.yml");
        write(ret.path, "dataDir: data\nsessionLockDir: locks\ndevinCommand: "~
            JSONValue(command).toString()~"\n"~ROUTER);
        ret.config = new Config(ret.path);
        ret.bridge = new Bridge(ret.config);
        ret.store = new ProfileStore(ret.config, ret.bridge);
        return ret;
    }

    void close()
    {
        rmdirRecurse(root);
    }
}

void installFake(Fixture fixture)
{
    import std.conv : octal;
    import std.file : getcwd, setAttributes;

    write(fixture.config.devinCommand, "#!/bin/sh\n"~
        `export AUTONOM_FAKE_DIR="`~fixture.root~`"`~"\n"~
        `export AUTONOM_FAKE_LOCKDIR="`~fixture.config.sessionLockDir~`"`~"\n"~
        `exec python3 "`~buildPath(getcwd(), "source", "tests", "fakeagent.py")~`" "$@"`~"\n");
    setAttributes(fixture.config.devinCommand, octal!"700");
}

void waitUntil(bool delegate() condition, Duration timeout = 5.seconds)
{
    MonoTime deadline = MonoTime.currTime + timeout;
    while (!condition())
    {
        if (MonoTime.currTime >= deadline)
            throw new Exception("Timed out waiting for test condition");

        Thread.sleep(10.msecs);
    }
}
