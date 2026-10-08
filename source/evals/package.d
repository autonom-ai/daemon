module evals;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : all;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.stdio : File;

public:

JSONValue request(
    string path,
    string body = null,
    uint status = 200,
    HTTP.Method method = HTTP.Method.undefined
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 130.seconds;
    client.method = method;
    if (body !is null)
        client.setPostData(body, "application/json");

    string data;
    client.onReceive = (ubyte[] chunk)
    {
        data ~= cast(char[])chunk;
        return chunk.length;
    };
    client.perform();
    enforce(client.statusLine.code == status,
        "HTTP "~client.statusLine.code.to!string~" for "~path~": "~data);
    return parseJSON(data);
}

struct Check
{
    string name;
    bool passed;
    string observed;
    Duration elapsed;
}

class Eval
{
private:
    MonoTime last;

public:
    const string name;
    Check[] checks;

    this(string name)
    {
        this.name = name;
        last = MonoTime.currTime;
    }

    bool check(string name, bool passed, string observed = null)
    {
        MonoTime now = MonoTime.currTime;
        checks ~= Check(name, passed, observed, now - last);
        last = now;
        return passed;
    }

    bool passed() const
        => checks.length && checks.all!(entry => entry.passed);

    void report(File output) const
    {
        output.writefln("%s %s", passed ? "PASS" : "FAIL", name);
        foreach (entry; checks)
        {
            output.writefln("  %s %-48s %6.1fs%s",
                entry.passed ? "pass" : "FAIL",
                entry.name,
                entry.elapsed.total!"msecs" / 1000.0,
                entry.observed.length ? "  "~entry.observed : "");
        }
    }
}

bool waitFor(bool delegate() condition, Duration timeout)
{
    MonoTime deadline = MonoTime.currTime + timeout;
    while (!condition())
    {
        if (MonoTime.currTime >= deadline)
            return false;

        Thread.sleep(10.msecs);
    }

    return true;
}
