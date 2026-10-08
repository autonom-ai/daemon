module evals.client;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;

private:

JSONValue request(
    string path,
    HTTP.Method method,
    JSONValue body,
    uint status
)
{
    HTTP client = HTTP("http://127.0.0.1:18080"~path);
    client.proxy = "";
    client.connectTimeout = 1.seconds;
    client.operationTimeout = 130.seconds;
    client.method = method;
    if (body.type != JSONType.null_)
        client.setPostData(body.toString(), "application/json");

    string content;
    client.onReceive = (ubyte[] chunk)
    {
        content ~= cast(char[])chunk;
        return chunk.length;
    };
    client.perform();
    enforce(client.statusLine.code == status,
        "HTTP "~client.statusLine.code.to!string~" for "~path~": "~content);
    return parseJSON(content);
}

public:

JSONValue get(string path, uint status = 200)
{
    return request(
        path,
        HTTP.Method.get,
        JSONValue(null),
        status
    );
}

JSONValue post(string path, JSONValue body = JSONValue.emptyObject, uint status = 200)
{
    return request(
        path,
        HTTP.Method.post,
        body,
        status
    );
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
