module tests.common;

import autonom.config : Config;
import autonom.profilestore : ProfileStore;
import autonom.session.devin : Devin;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.exception : enforce;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.uuid : randomUUID;

public:

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
