module tests.common;

import autonom.agent : ProfileStore;
import autonom.config : Config;
import autonom.interop.devin : Devin;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath;
import std.uuid : randomUUID;

public:

/// Performs an HTTP request against the daemon under test.
JSONValue request(
    string path,
    uint status = 200,
    string data = null,
    string contentType = "application/json",
    HTTP.Method method = HTTP.Method.undefined
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 2.seconds;
    client.method = method;
    if (data !is null)
        client.setPostData(data, contentType);

    string body;
    client.onReceive = (ubyte[] chunk)
    {
        body ~= cast(char[])chunk;
        return chunk.length;
    };
    client.perform();
    enforce(client.statusLine.code == status,
        "HTTP "~client.statusLine.code.to!string~" for "~path~": "~body);
    return parseJSON(body);
}

struct Fixture
{
public:
    string root;
    string path;
    Config config;
    Devin bridge;
    ProfileStore store;

    static Fixture create(string command = "./devin")
    {
        Fixture ret;
        ret.root = buildPath(tempDir(), "autonom-"~randomUUID().toString());
        mkdirRecurse(ret.root);
        scope(failure)
            rmdirRecurse(ret.root);

        ret.path = buildPath(ret.root, "config.yml");
        write(ret.path, "dataDir: data\nsessionLockDir: locks\ndevinCommand: "~JSONValue(command).toString()~"\n");
        ret.config = new Config(ret.path);
        ret.bridge = new Devin(ret.config);
        ret.store = new ProfileStore(ret.config, ret.bridge);
        return ret;
    }

    void close()
    {
        rmdirRecurse(root);
    }
}

void waitUntil(bool delegate() condition, Duration timeout = 5.seconds)
{
    MonoTime deadline = MonoTime.currTime + timeout;
    while (!condition())
    {
        enforce(MonoTime.currTime < deadline, "Timed out waiting for test condition");
        Thread.sleep(10.msecs);
    }
}
