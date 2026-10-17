module daemon.interop.acp.frames;

import std.json : JSONType, JSONValue, parseJSON;

// Shared by both daemon-owned and Desktop ACP connections.
enum frameLimit = 16 * 1024 * 1024;
enum requestLimit = 256;

struct Frame
{
    JSONValue value;

    this(JSONValue value)
    {
        this.value = value;
        validate();
    }

    bool request() const
        => value.type == JSONType.object && "method" in value.object;

    bool identified() const
        => ("id" in value.object) !is null;

    string method() const
        => request ? value["method"].str : null;

    string key() const
        => identified ? value["id"].toString() : null;

    Frame withId(JSONValue id)
    {
        // JSONValue copies share their object storage. Routing must retain the peer's identity.
        Frame ret = this;
        ret.value = JSONValue(value.object.dup);
        ret.value["id"] = id;
        return ret;
    }

    string encode()
    {
        string ret = value.toString();
        if (ret.length > frameLimit)
            throw new Exception("ACP frame exceeds the 16 MiB limit");
        return ret~"\n";
    }

    void validate()
    {
        if (value.type != JSONType.object || "jsonrpc" !in value.object ||
            value["jsonrpc"].type != JSONType.string || value["jsonrpc"].str != "2.0")
            throw new Exception("Invalid ACP envelope");
        if (identified)
        {
            JSONType type = value["id"].type;
            if (type != JSONType.string && type != JSONType.integer &&
                type != JSONType.uinteger && type != JSONType.null_)
                throw new Exception("Invalid ACP request identity");
        }
        if (request)
        {
            if (value["method"].type != JSONType.string || !value["method"].str.length ||
                "result" in value.object || "error" in value.object)
                throw new Exception("Invalid ACP request");
        }
        else if (!identified || (("result" in value.object) !is null) == (("error" in value.object) !is null))
            throw new Exception("Invalid ACP response");
    }
}

struct FrameReader
{
private:
    char[] partial;

public:
    void feed(const(ubyte)[] bytes, void delegate(Frame) receive) {
        foreach (value; bytes)
        {
            if (value == '\n')
            {
                if (!partial.length)
                    continue;
                Frame frame = Frame(parseJSON(partial));
                partial = null;
                receive(frame);
            }
            else
            {
                if (partial.length >= frameLimit)
                    throw new Exception("ACP frame exceeds the 16 MiB limit");
                partial ~= cast(char)value;
            }
        }
    }

    void finish()
    {
        if (partial.length)
            throw new Exception("ACP stream ended within a frame");
    }
}
